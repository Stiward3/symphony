defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Client, Tracker}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @jira_issue_update_tool "jira_issue_update"
  @jira_issue_update_description """
  Create a Jira comment and/or transition a Jira issue using Symphony's configured Jira auth.
  """
  @github_delivery_tool "github_delivery"
  @github_delivery_description """
  Commit workspace changes, push the current branch to origin, and create or update the corresponding GitHub pull request using Symphony's host environment.
  """
  @jira_issue_update_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueId"],
    "properties" => %{
      "issueId" => %{
        "type" => "string",
        "description" => "Jira issue key or id to update."
      },
      "comment" => %{
        "type" => ["string", "null"],
        "description" => "Optional Jira comment body to add."
      },
      "state" => %{
        "type" => ["string", "null"],
        "description" => "Optional Jira workflow state name to transition the issue to."
      }
    }
  }
  @github_delivery_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["commitMessage", "prTitle"],
    "properties" => %{
      "commitMessage" => %{
        "type" => "string",
        "description" => "Full git commit message to use for the delivery commit."
      },
      "prTitle" => %{
        "type" => "string",
        "description" => "Pull request title."
      },
      "prBody" => %{
        "type" => ["string", "null"],
        "description" => "Optional pull request body markdown."
      },
      "repoOwner" => %{
        "type" => ["string", "null"],
        "description" => "Optional GitHub owner for a dedicated delivery repo."
      },
      "repoName" => %{
        "type" => ["string", "null"],
        "description" => "Optional GitHub repository name for a dedicated delivery repo."
      },
      "repoVisibility" => %{
        "type" => ["string", "null"],
        "description" => "Optional visibility for a dedicated delivery repo. Allowed values: private, public, internal."
      },
      "paths" => %{
        "type" => ["array", "null"],
        "description" => "Optional list of repo-relative paths to stage. When omitted, all workspace changes are staged.",
        "items" => %{"type" => "string"}
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @jira_issue_update_tool ->
        execute_jira_issue_update(arguments, opts)

      @github_delivery_tool ->
        execute_github_delivery(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.settings!().tracker.kind do
      "jira" ->
        [
          %{
            "name" => @jira_issue_update_tool,
            "description" => @jira_issue_update_description,
            "inputSchema" => @jira_issue_update_input_schema
          },
          %{
            "name" => @github_delivery_tool,
            "description" => @github_delivery_description,
            "inputSchema" => @github_delivery_input_schema
          }
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_jira_issue_update(arguments, opts) do
    create_comment = Keyword.get(opts, :tracker_create_comment, &Tracker.create_comment/2)
    update_issue_state = Keyword.get(opts, :tracker_update_issue_state, &Tracker.update_issue_state/2)

    with :ok <- ensure_jira_tracker_configured(),
         {:ok, issue_id, comment, state_name} <- normalize_jira_issue_update_arguments(arguments),
         :ok <- log_jira_issue_update(issue_id, comment, state_name),
         :ok <- maybe_create_jira_comment(issue_id, comment, create_comment),
         :ok <- maybe_update_jira_state(issue_id, state_name, update_issue_state) do
      %{
        "issueId" => issue_id,
        "commentCreated" => is_binary(comment),
        "stateUpdated" => state_name
      }
      |> success_response()
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_github_delivery(arguments, opts) do
    command_runner = Keyword.get(opts, :command_runner, &default_command_runner/3)
    executable_finder = Keyword.get(opts, :executable_finder, &System.find_executable/1)
    workspace = Keyword.get(opts, :workspace)

    with {:ok, workspace} <- normalize_workspace(workspace),
         {:ok, commit_message, pr_title, pr_body, paths, repo_owner, repo_name, repo_visibility} <-
           normalize_github_delivery_arguments(arguments),
         {:ok, _git_path} <- ensure_executable_available("git", executable_finder),
         {:ok, _gh_path} <- ensure_executable_available("gh", executable_finder),
         :ok <- stage_github_delivery_changes(workspace, paths, command_runner),
         {:ok, changed?} <- workspace_has_changes?(workspace, command_runner),
         :ok <- ensure_github_delivery_changes(changed?),
         {:ok, commit_sha} <- create_github_delivery_commit(workspace, commit_message, command_runner),
         {:ok, branch} <- current_branch(workspace, command_runner),
         {:ok, delivery_target} <-
           resolve_delivery_target(
             workspace,
             repo_owner,
             repo_name,
             repo_visibility,
             command_runner
           ),
         :ok <- push_current_branch(workspace, delivery_target.remote, command_runner),
         {:ok, pr_result} <-
           ensure_pull_request(
             workspace,
             branch,
             pr_title,
             pr_body,
             delivery_target.repo_selector,
             command_runner
           ) do
      %{
        "branch" => branch,
        "branchUrl" => branch_url(delivery_target.repo_url, branch),
        "commitSha" => commit_sha,
        "pr" => pr_result,
        "repoUrl" => delivery_target.repo_url
      }
      |> success_response()
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_jira_issue_update_arguments(arguments) when is_map(arguments) do
    issue_id =
      Map.get(arguments, "issueId") ||
        Map.get(arguments, :issueId) ||
        Map.get(arguments, "issue_id") ||
        Map.get(arguments, :issue_id)

    comment = Map.get(arguments, "comment") || Map.get(arguments, :comment)
    state_name = Map.get(arguments, "state") || Map.get(arguments, :state)

    with {:ok, normalized_issue_id} <- normalize_required_string(issue_id, :missing_issue_id),
         {:ok, normalized_comment} <- normalize_optional_string(comment),
         {:ok, normalized_state} <- normalize_optional_string(state_name),
         :ok <- ensure_jira_issue_update_action(normalized_comment, normalized_state) do
      {:ok, normalized_issue_id, normalized_comment, normalized_state}
    end
  end

  defp normalize_jira_issue_update_arguments(_arguments), do: {:error, :invalid_jira_issue_update_arguments}

  defp normalize_github_delivery_arguments(arguments) when is_map(arguments) do
    commit_message =
      Map.get(arguments, "commitMessage") ||
        Map.get(arguments, :commitMessage) ||
        Map.get(arguments, "commit_message") ||
        Map.get(arguments, :commit_message)

    pr_title =
      Map.get(arguments, "prTitle") ||
        Map.get(arguments, :prTitle) ||
        Map.get(arguments, "pr_title") ||
        Map.get(arguments, :pr_title)

    pr_body =
      Map.get(arguments, "prBody") ||
        Map.get(arguments, :prBody) ||
        Map.get(arguments, "pr_body") ||
        Map.get(arguments, :pr_body)

    repo_owner =
      Map.get(arguments, "repoOwner") ||
        Map.get(arguments, :repoOwner) ||
        Map.get(arguments, "repo_owner") ||
        Map.get(arguments, :repo_owner)

    repo_name =
      Map.get(arguments, "repoName") ||
        Map.get(arguments, :repoName) ||
        Map.get(arguments, "repo_name") ||
        Map.get(arguments, :repo_name)

    repo_visibility =
      Map.get(arguments, "repoVisibility") ||
        Map.get(arguments, :repoVisibility) ||
        Map.get(arguments, "repo_visibility") ||
        Map.get(arguments, :repo_visibility)

    paths =
      Map.get(arguments, "paths") ||
        Map.get(arguments, :paths)

    with {:ok, normalized_commit_message} <-
           normalize_required_string(commit_message, :missing_github_delivery_commit_message),
         {:ok, normalized_pr_title} <-
           normalize_required_string(pr_title, :missing_github_delivery_pr_title),
         {:ok, normalized_pr_body} <-
           normalize_optional_string(pr_body, :invalid_github_delivery_arguments),
         {:ok, normalized_paths} <- normalize_optional_path_list(paths),
         {:ok, normalized_repo_owner, normalized_repo_name} <-
           normalize_optional_repo_target(repo_owner, repo_name),
         {:ok, normalized_repo_visibility} <-
           normalize_repo_visibility(repo_visibility) do
      {:ok, normalized_commit_message, normalized_pr_title, normalized_pr_body, normalized_paths,
       normalized_repo_owner, normalized_repo_name, normalized_repo_visibility}
    end
  end

  defp normalize_github_delivery_arguments(_arguments), do: {:error, :invalid_github_delivery_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_required_string(value, error_reason) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error_reason}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_required_string(_value, error_reason), do: {:error, error_reason}

  defp normalize_optional_string(nil), do: {:ok, nil}

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_optional_string(_value), do: {:error, :invalid_jira_issue_update_arguments}

  defp normalize_optional_string(nil, _error_reason), do: {:ok, nil}

  defp normalize_optional_string(value, _error_reason) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_optional_string(_value, error_reason), do: {:error, error_reason}

  defp normalize_optional_path_list(nil), do: {:ok, nil}

  defp normalize_optional_path_list(paths) when is_list(paths) do
    normalized_paths =
      Enum.reduce_while(paths, [], fn path, acc ->
        case normalize_required_string(path, :invalid_github_delivery_arguments) do
          {:ok, normalized_path} -> {:cont, [normalized_path | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case normalized_paths do
      {:error, reason} -> {:error, reason}
      paths -> {:ok, Enum.reverse(paths)}
    end
  end

  defp normalize_optional_path_list(_paths), do: {:error, :invalid_github_delivery_arguments}

  defp normalize_optional_repo_target(nil, nil), do: {:ok, nil, nil}

  defp normalize_optional_repo_target(repo_owner, repo_name) do
    with {:ok, normalized_repo_owner} <-
           normalize_required_string(repo_owner, :invalid_github_delivery_arguments),
         {:ok, normalized_repo_name} <-
           normalize_required_string(repo_name, :invalid_github_delivery_arguments) do
      {:ok, normalized_repo_owner, normalized_repo_name}
    else
      {:error, _reason} -> {:error, :invalid_github_delivery_arguments}
    end
  end

  defp normalize_repo_visibility(nil) do
    case System.get_env("GITHUB_REPO_VISIBILITY") do
      value when is_binary(value) -> normalize_repo_visibility(value)
      _ -> {:ok, "private"}
    end
  end

  defp normalize_repo_visibility(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      visibility when visibility in ["private", "public", "internal"] -> {:ok, visibility}
      _ -> {:error, :invalid_github_delivery_arguments}
    end
  end

  defp normalize_repo_visibility(_value), do: {:error, :invalid_github_delivery_arguments}

  defp ensure_jira_issue_update_action(nil, nil), do: {:error, :missing_jira_issue_update_action}
  defp ensure_jira_issue_update_action(_comment, _state), do: :ok

  defp maybe_create_jira_comment(issue_id, comment, create_comment)
       when is_binary(issue_id) and is_binary(comment) and is_function(create_comment, 2) do
    case create_comment.(issue_id, comment) do
      :ok -> :ok
      {:error, reason} -> {:error, {:jira_comment_failed, reason}}
    end
  end

  defp maybe_create_jira_comment(_issue_id, nil, _create_comment), do: :ok

  defp maybe_update_jira_state(issue_id, state_name, update_issue_state)
       when is_binary(issue_id) and is_binary(state_name) and is_function(update_issue_state, 2) do
    case update_issue_state.(issue_id, state_name) do
      :ok -> :ok
      {:error, reason} -> {:error, {:jira_state_update_failed, reason}}
    end
  end

  defp maybe_update_jira_state(_issue_id, nil, _update_issue_state), do: :ok

  defp stage_github_delivery_changes(workspace, nil, command_runner) do
    case run_command(command_runner, "git", ["add", "-A"], workspace) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:github_delivery_stage_failed, reason}}
    end
  end

  defp stage_github_delivery_changes(workspace, paths, command_runner) when is_list(paths) do
    case run_command(command_runner, "git", ["add", "--" | paths], workspace) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:github_delivery_stage_failed, reason}}
    end
  end

  defp workspace_has_changes?(workspace, command_runner) do
    case run_command(command_runner, "git", ["status", "--porcelain"], workspace) do
      {:ok, output} -> {:ok, String.trim(output) != ""}
      {:error, reason} -> {:error, {:github_delivery_status_failed, reason}}
    end
  end

  defp ensure_github_delivery_changes(true), do: :ok
  defp ensure_github_delivery_changes(false), do: {:error, :github_delivery_no_changes}

  defp create_github_delivery_commit(workspace, commit_message, command_runner) do
    commit_file =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-delivery-#{System.unique_integer([:positive, :monotonic])}.txt"
      )

    try do
      File.write!(commit_file, commit_message)

      case run_command(command_runner, "git", ["commit", "-F", commit_file], workspace) do
        {:ok, _output} -> current_commit_sha(workspace, command_runner)
        {:error, reason} -> {:error, {:github_delivery_commit_failed, reason}}
      end
    rescue
      error in [File.Error] ->
        {:error, {:github_delivery_commit_failed, Exception.message(error)}}
    after
      File.rm(commit_file)
    end
  end

  defp current_commit_sha(workspace, command_runner) do
    case run_command(command_runner, "git", ["rev-parse", "HEAD"], workspace) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:github_delivery_rev_parse_failed, reason}}
    end
  end

  defp current_branch(workspace, command_runner) do
    case run_command(command_runner, "git", ["branch", "--show-current"], workspace) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> {:error, :github_delivery_missing_branch}
          branch -> {:ok, branch}
        end

      {:error, reason} ->
        {:error, {:github_delivery_branch_failed, reason}}
    end
  end

  defp resolve_delivery_target(workspace, nil, nil, _repo_visibility, command_runner) do
    with {:ok, repo_url} <- origin_url(workspace, command_runner) do
      {:ok, %{remote: "origin", repo_selector: nil, repo_url: repo_url}}
    end
  end

  defp resolve_delivery_target(workspace, repo_owner, repo_name, repo_visibility, command_runner)
       when is_binary(repo_owner) and is_binary(repo_name) and is_binary(repo_visibility) do
    with {:ok, repo_info} <-
           ensure_dedicated_repo(workspace, repo_owner, repo_name, repo_visibility, command_runner),
         :ok <- configure_delivery_remote(workspace, repo_info, command_runner) do
      {:ok,
       %{
         remote: "delivery",
         repo_selector: repo_info.repo_selector,
         repo_url: repo_info.repo_url
       }}
    end
  end

  defp push_current_branch(workspace, remote_name, command_runner) do
    case run_command(command_runner, "git", ["push", "-u", remote_name, "HEAD"], workspace) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:github_delivery_push_failed, reason}}
    end
  end

  defp ensure_pull_request(workspace, branch, pr_title, pr_body, repo_selector, command_runner) do
    case view_pull_request(workspace, repo_selector, command_runner) do
      {:ok, %{"state" => state} = payload} when state in ["CLOSED", "MERGED"] ->
        {:error, {:github_delivery_closed_pr, Map.get(payload, "url")}}

      {:ok, %{"url" => url}} ->
        with :ok <- update_pull_request(workspace, pr_title, pr_body, repo_selector, command_runner) do
          {:ok, %{"action" => "updated", "url" => url}}
        end

      {:error, {:command_failed, _message, 1}} ->
        create_pull_request(workspace, branch, pr_title, pr_body, repo_selector, command_runner)

      {:error, reason} ->
        {:error, {:github_delivery_pr_view_failed, reason}}
    end
  end

  defp view_pull_request(workspace, repo_selector, command_runner) do
    with {:ok, output} <-
           run_command(
             command_runner,
              "gh",
             github_repo_selector_args(repo_selector) ++ ["pr", "view", "--json", "state,url"],
             workspace
           ) do
      case Jason.decode(output) do
        {:ok, payload} -> {:ok, payload}
        {:error, error} -> {:error, Exception.message(error)}
      end
    end
  end

  defp update_pull_request(workspace, pr_title, pr_body, repo_selector, command_runner) do
    args =
      github_repo_selector_args(repo_selector) ++
        ["pr", "edit", "--title", pr_title] ++
        maybe_pr_body_args(pr_body)

    case run_command(command_runner, "gh", args, workspace) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:github_delivery_pr_edit_failed, reason}}
    end
  end

  defp create_pull_request(workspace, branch, pr_title, pr_body, repo_selector, command_runner) do
    args =
      github_repo_selector_args(repo_selector) ++
        ["pr", "create", "--head", branch, "--title", pr_title] ++
        maybe_pr_body_args(pr_body)

    with {:ok, _output} <- run_command(command_runner, "gh", args, workspace),
         {:ok, %{"url" => url}} <- view_pull_request(workspace, repo_selector, command_runner) do
      {:ok, %{"action" => "created", "url" => url}}
    else
      {:error, reason} -> {:error, {:github_delivery_pr_create_failed, reason}}
    end
  end

  defp maybe_pr_body_args(nil), do: []

  defp maybe_pr_body_args(pr_body) when is_binary(pr_body) do
    ["--body", pr_body]
  end

  defp ensure_dedicated_repo(workspace, repo_owner, repo_name, repo_visibility, command_runner) do
    repo_selector = "#{repo_owner}/#{repo_name}"
    repo_url = "https://github.com/#{repo_selector}.git"

    case run_command(
           command_runner,
           "gh",
           ["repo", "view", repo_selector, "--json", "nameWithOwner,url"],
           workspace
         ) do
      {:ok, _output} ->
        {:ok, %{repo_selector: repo_selector, repo_url: repo_url}}

      {:error, {:command_failed, _output, 1}} ->
        create_dedicated_repo(workspace, repo_selector, repo_url, repo_visibility, command_runner)

      {:error, reason} ->
        {:error, {:github_delivery_repo_view_failed, reason}}
    end
  end

  defp create_dedicated_repo(workspace, repo_selector, repo_url, repo_visibility, command_runner) do
    case run_command(
           command_runner,
           "gh",
           ["repo", "create", repo_selector, "--#{repo_visibility}", "--confirm"],
           workspace
         ) do
      {:ok, _output} ->
        {:ok, %{repo_selector: repo_selector, repo_url: repo_url}}

      {:error, reason} ->
        {:error, {:github_delivery_repo_create_failed, reason}}
    end
  end

  defp configure_delivery_remote(workspace, %{repo_url: repo_url}, command_runner)
       when is_binary(repo_url) do
    case git_remote_exists?(workspace, "delivery", command_runner) do
      {:ok, true} ->
        case run_command(command_runner, "git", ["remote", "set-url", "delivery", repo_url], workspace) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:github_delivery_remote_failed, reason}}
        end

      {:ok, false} ->
        case run_command(command_runner, "git", ["remote", "add", "delivery", repo_url], workspace) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:github_delivery_remote_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:github_delivery_remote_failed, reason}}
    end
  end

  defp git_remote_exists?(workspace, remote_name, command_runner) do
    case run_command(command_runner, "git", ["remote"], workspace) do
      {:ok, output} ->
        remotes =
          output
          |> String.split("\n", trim: true)
          |> MapSet.new()

        {:ok, MapSet.member?(remotes, remote_name)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp github_repo_selector_args(nil), do: []
  defp github_repo_selector_args(repo_selector), do: ["-R", repo_selector]

  defp branch_url(repo_url, branch) when is_binary(repo_url) and is_binary(branch) do
    case repo_web_url(repo_url) do
      nil -> nil
      web_url -> web_url <> "/tree/" <> branch
    end
  end

  defp branch_url(_repo_url, _branch), do: nil

  defp repo_web_url(repo_url) when is_binary(repo_url) do
    normalized =
      repo_url
      |> String.trim()
      |> String.trim_trailing(".git")

    cond do
      normalized == "" ->
        nil

      String.starts_with?(normalized, "https://github.com/") ->
        normalized

      String.starts_with?(normalized, "http://github.com/") ->
        normalized

      String.starts_with?(normalized, "git@github.com:") ->
        "https://github.com/" <> String.replace_prefix(normalized, "git@github.com:", "")

      String.starts_with?(normalized, "ssh://git@github.com/") ->
        "https://github.com/" <> String.replace_prefix(normalized, "ssh://git@github.com/", "")

      true ->
        nil
    end
  end

  defp repo_web_url(_repo_url), do: nil

  defp origin_url(workspace, command_runner) do
    case run_command(command_runner, "git", ["remote", "get-url", "origin"], workspace) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:github_delivery_origin_failed, reason}}
    end
  end

  defp ensure_executable_available(command, executable_finder)
       when is_binary(command) and is_function(executable_finder, 1) do
    case executable_finder.(command) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, {:missing_executable, command}}
    end
  end

  defp normalize_workspace(workspace) when is_binary(workspace) do
    case String.trim(workspace) do
      "" -> {:error, :missing_github_delivery_workspace}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_workspace(_workspace), do: {:error, :missing_github_delivery_workspace}

  defp run_command(command_runner, command, args, workspace)
       when is_function(command_runner, 3) and is_binary(command) and is_list(args) and
              is_binary(workspace) do
    case command_runner.(command, args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, IO.iodata_to_binary(output)}

      {output, status} ->
        {:error, {:command_failed, IO.iodata_to_binary(output), status}}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp default_command_runner(command, args, opts) do
    System.cmd(command, args, opts)
  end

  defp ensure_jira_tracker_configured do
    if Config.settings!().tracker.kind == "jira" do
      :ok
    else
      {:error, :jira_tool_unavailable}
    end
  end

  defp log_jira_issue_update(issue_id, comment, state_name)
       when is_binary(issue_id) do
    Logger.info(
      "jira_issue_update called issue_id=#{issue_id} comment_present=#{is_binary(comment)} comment_chars=#{if(is_binary(comment), do: String.length(comment), else: 0)} state=#{inspect(state_name)}"
    )

    :ok
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:jira_tool_unavailable) do
    %{
      "error" => %{
        "message" => "`jira_issue_update` is only available when Symphony is configured with `tracker.kind: jira`."
      }
    }
  end

  defp tool_error_payload(:missing_issue_id) do
    %{
      "error" => %{
        "message" => "`jira_issue_update` requires a non-empty `issueId` string."
      }
    }
  end

  defp tool_error_payload(:missing_jira_issue_update_action) do
    %{
      "error" => %{
        "message" => "`jira_issue_update` requires at least one of `comment` or `state`."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_issue_update_arguments) do
    %{
      "error" => %{
        "message" => "`jira_issue_update` expects an object with `issueId` and optional `comment` and `state` strings."
      }
    }
  end

  defp tool_error_payload(:missing_github_delivery_workspace) do
    %{
      "error" => %{
        "message" => "`github_delivery` requires a current workspace."
      }
    }
  end

  defp tool_error_payload(:missing_github_delivery_commit_message) do
    %{
      "error" => %{
        "message" => "`github_delivery` requires a non-empty `commitMessage` string."
      }
    }
  end

  defp tool_error_payload(:missing_github_delivery_pr_title) do
    %{
      "error" => %{
        "message" => "`github_delivery` requires a non-empty `prTitle` string."
      }
    }
  end

  defp tool_error_payload(:invalid_github_delivery_arguments) do
    %{
      "error" => %{
        "message" => "`github_delivery` expects an object with `commitMessage`, `prTitle`, optional `prBody`, and optional string `paths` entries."
      }
    }
  end

  defp tool_error_payload(:github_delivery_no_changes) do
    %{
      "error" => %{
        "message" => "`github_delivery` found no workspace changes to commit after staging."
      }
    }
  end

  defp tool_error_payload(:github_delivery_missing_branch) do
    %{
      "error" => %{
        "message" => "`github_delivery` could not determine the current git branch."
      }
    }
  end

  defp tool_error_payload({:missing_executable, command}) do
    %{
      "error" => %{
        "message" => "`github_delivery` requires `#{command}` to be available in Symphony's host environment."
      }
    }
  end

  defp tool_error_payload({:github_delivery_closed_pr, url}) do
    %{
      "error" => %{
        "message" => "`github_delivery` found a closed or merged pull request for the current branch.",
        "url" => url
      }
    }
  end

  defp tool_error_payload({stage, reason})
       when stage in [
              :github_delivery_stage_failed,
              :github_delivery_status_failed,
              :github_delivery_commit_failed,
              :github_delivery_rev_parse_failed,
              :github_delivery_branch_failed,
              :github_delivery_push_failed,
              :github_delivery_pr_view_failed,
              :github_delivery_pr_edit_failed,
              :github_delivery_pr_create_failed,
              :github_delivery_origin_failed,
              :github_delivery_repo_view_failed,
              :github_delivery_repo_create_failed,
              :github_delivery_remote_failed
            ] do
    %{
      "error" => %{
        "message" => github_delivery_stage_message(stage),
        "reason" => format_github_delivery_reason(reason)
      }
    }
  end

  defp tool_error_payload({:jira_comment_failed, reason}) do
    %{
      "error" => %{
        "message" => "Jira comment creation failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:jira_state_update_failed, reason}) do
    %{
      "error" => %{
        "message" => "Jira state transition failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp github_delivery_stage_message(:github_delivery_stage_failed),
    do: "GitHub delivery failed while staging changes."

  defp github_delivery_stage_message(:github_delivery_status_failed),
    do: "GitHub delivery failed while checking git status."

  defp github_delivery_stage_message(:github_delivery_commit_failed),
    do: "GitHub delivery failed while creating the git commit."

  defp github_delivery_stage_message(:github_delivery_rev_parse_failed),
    do: "GitHub delivery failed while reading the new commit SHA."

  defp github_delivery_stage_message(:github_delivery_branch_failed),
    do: "GitHub delivery failed while reading the current branch."

  defp github_delivery_stage_message(:github_delivery_push_failed),
    do: "GitHub delivery failed while pushing the current branch."

  defp github_delivery_stage_message(:github_delivery_pr_view_failed),
    do: "GitHub delivery failed while checking the current pull request."

  defp github_delivery_stage_message(:github_delivery_pr_edit_failed),
    do: "GitHub delivery failed while updating the pull request."

  defp github_delivery_stage_message(:github_delivery_pr_create_failed),
    do: "GitHub delivery failed while creating the pull request."

  defp github_delivery_stage_message(:github_delivery_origin_failed),
    do: "GitHub delivery failed while reading the origin remote URL."

  defp github_delivery_stage_message(:github_delivery_repo_view_failed),
    do: "GitHub delivery failed while checking the dedicated repository."

  defp github_delivery_stage_message(:github_delivery_repo_create_failed),
    do: "GitHub delivery failed while creating the dedicated repository."

  defp github_delivery_stage_message(:github_delivery_remote_failed),
    do: "GitHub delivery failed while configuring the dedicated git remote."

  defp format_github_delivery_reason({:command_failed, output, status}) do
    "command exited with status #{status}: #{String.trim(output)}"
  end

  defp format_github_delivery_reason(reason) when is_binary(reason), do: reason
  defp format_github_delivery_reason(reason), do: inspect(reason)

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
