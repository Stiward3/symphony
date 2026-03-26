defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, codex_update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, codex_update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        run_on_worker_hosts(issue, codex_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _codex_update_recipient, _opts, []), do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    Process.put(:codex_turn_meaningful_activity, false)
    on_message = tracking_codex_message_handler(codex_update_recipient, issue)

    try do
      with {:ok, turn_session} <-
             AppServer.run_turn(
               app_session,
               prompt,
               issue,
               on_message: on_message
             ) do
        if Process.get(:codex_turn_meaningful_activity, false) do
          Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

          case continue_with_issue?(issue, issue_state_fetcher) do
            {:continue, refreshed_issue} when turn_number < max_turns ->
              Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

              do_run_codex_turns(
                app_session,
                workspace,
                refreshed_issue,
                codex_update_recipient,
                opts,
                issue_state_fetcher,
                turn_number + 1,
                max_turns
              )

            {:continue, refreshed_issue} ->
              Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

              :ok

            {:done, _refreshed_issue} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        else
          Logger.warning(
            "Codex turn completed without meaningful activity for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}"
          )

          {:error, :codex_turn_completed_without_meaningful_activity}
        end
      end
    after
      Process.delete(:codex_turn_meaningful_activity)
    end
  end

  defp tracking_codex_message_handler(recipient, issue) do
    delegate = codex_message_handler(recipient, issue)

    fn message ->
      if meaningful_codex_update?(message) do
        Process.put(:codex_turn_meaningful_activity, true)
      end

      delegate.(message)
    end
  end

  defp meaningful_codex_update?(%{event: event} = message) do
    case event do
      :tool_call_completed -> true
      :tool_call_failed -> true
      :unsupported_tool_call -> true
      :notification -> meaningful_codex_notification?(message)
      _ -> false
    end
  end

  defp meaningful_codex_update?(_message), do: false

  defp meaningful_codex_notification?(%{payload: payload}) when is_map(payload) do
    case Map.get(payload, "method") do
      "codex/event/exec_command_begin" -> true
      "codex/event/exec_command_end" -> true
      "codex/event/exec_command_output_delta" -> true
      "codex/event/mcp_tool_call_begin" -> true
      "codex/event/mcp_tool_call_end" -> true
      "codex/event/token_count" -> true
      "codex/event/agent_message_delta" -> true
      "codex/event/agent_message_content_delta" -> true
      "codex/event/agent_reasoning_delta" -> true
      "codex/event/reasoning_content_delta" -> true
      "codex/event/agent_reasoning" -> true
      "codex/event/task_started" -> true
      "codex/event/item_started" -> meaningful_item_payload?(payload)
      "codex/event/item_completed" -> meaningful_item_payload?(payload)
      _ -> false
    end
  end

  defp meaningful_codex_notification?(_message), do: false

  defp meaningful_item_payload?(payload) when is_map(payload) do
    case get_in(payload, ["params", "msg", "type"]) do
      "token_count" -> true
      type when is_binary(type) -> type != "user_message"
      _ -> false
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    tracker_issue_label = tracker_issue_label()

    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the #{tracker_issue_label} is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - If the tracker is Jira, use `jira_issue_update` for issue comments and state transitions.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp tracker_issue_label do
    case Config.settings!().tracker.kind do
      "jira" -> "Jira issue"
      _ -> "Linear issue"
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if continuation_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp continuation_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)
    active_issue_state?(state_name) or normalized_state == "in progress"
  end

  defp continuation_issue_state?(_state_name), do: false

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
