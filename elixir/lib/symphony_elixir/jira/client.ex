defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira REST client for polling candidate issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @search_page_size 50
  @max_error_body_log_bytes 1_000
  @workpad_comment_header "## Codex Workpad"
  @search_fields [
    "summary",
    "description",
    "status",
    "priority",
    "labels",
    "assignee",
    "parent",
    "created",
    "updated",
    "issuelinks"
  ]

  @type request_result :: {:ok, %{status: integer(), body: term()}} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      do_fetch_by_states(tracker.active_states, assignee_filter)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker) do
      state_names
      |> normalize_state_names()
      |> case do
        [] -> {:ok, []}
        normalized -> do_fetch_by_states(normalized, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker
    ids = issue_ids |> Enum.uniq() |> Enum.filter(&non_empty_string?/1)

    with :ok <- validate_tracker_config(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      case ids do
        [] ->
          {:ok, []}

        _ ->
          ids
          |> build_issue_id_jql()
          |> do_search(nil, assignee_filter)
          |> sort_issues_by_requested_ids(ids)
      end
    end
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, opts \\ [])
      when is_binary(issue_id) and is_binary(body) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &request/4)

    with {:ok, response} <- upsert_comment_request(issue_id, body, request_fun),
         true <- response.status in [200, 201] do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  defp jira_comment_payload(body) when is_binary(body) do
    %{
      "body" => %{
        "type" => "doc",
        "version" => 1,
        "content" => comment_paragraphs(body)
      }
    }
  end

  defp comment_paragraphs(body) when is_binary(body) do
    body
    |> String.split(~r/
?

?
/, trim: false)
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> [comment_paragraph("")]
      paragraphs -> Enum.map(paragraphs, &comment_paragraph/1)
    end
  end

  defp comment_paragraph(text) when is_binary(text) do
    %{
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "text",
          "text" => text
        }
      ]
    }
  end

  defp upsert_comment_request(issue_id, body, request_fun)
       when is_binary(issue_id) and is_binary(body) and is_function(request_fun, 4) do
    payload = jira_comment_payload(body)

    if workpad_comment?(body) do
      case find_existing_workpad_comment_id(issue_id, request_fun) do
        {:ok, comment_id} ->
          request_fun.(:put, "issue/#{issue_id}/comment/#{comment_id}", payload, [])

        {:error, :workpad_comment_not_found} ->
          request_fun.(:post, "issue/#{issue_id}/comment", payload, [])

        {:error, reason} ->
          {:error, reason}
      end
    else
      request_fun.(:post, "issue/#{issue_id}/comment", payload, [])
    end
  end

  defp find_existing_workpad_comment_id(issue_id, request_fun)
       when is_binary(issue_id) and is_function(request_fun, 4) do
    with {:ok, response} <- request_fun.(:get, "issue/#{issue_id}/comment", nil, []),
         true <- response.status == 200,
         comments when is_list(comments) <- Map.get(response.body, "comments"),
         comment_id when is_binary(comment_id) <- latest_workpad_comment_id(comments) do
      {:ok, comment_id}
    else
      false -> {:error, :comment_lookup_failed}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :workpad_comment_not_found}
      _ -> {:error, :comment_lookup_failed}
    end
  end

  defp latest_workpad_comment_id(comments) when is_list(comments) do
    comments
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"id" => id, "body" => comment_body} when is_binary(id) ->
        if workpad_comment_body?(comment_body), do: id

      _ ->
        nil
    end)
  end

  defp workpad_comment?(body) when is_binary(body) do
    String.contains?(body, @workpad_comment_header)
  end

  defp workpad_comment_body?(body) when is_binary(body) do
    String.contains?(body, @workpad_comment_header)
  end

  defp workpad_comment_body?(body) when is_map(body) do
    case extract_description(body) do
      description when is_binary(description) -> String.contains?(description, @workpad_comment_header)
      _ -> false
    end
  end

  defp workpad_comment_body?(_body), do: false

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, opts \\ [])
      when is_binary(issue_id) and is_binary(state_name) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &request/4)

    with {:ok, transition_id} <- resolve_transition_id(issue_id, state_name, request_fun),
         {:ok, response} <-
           request_fun.(
             :post,
             "issue/#{issue_id}/transitions",
             %{"transition" => %{"id" => transition_id}},
             []
           ),
         true <- response.status in [200, 204] do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee \\ nil) when is_map(issue) do
    normalize_issue(issue, build_assignee_filter_for_test(assignee))
  end

  defp do_fetch_by_states(state_names, assignee_filter) do
    state_names
    |> build_state_jql()
    |> do_search(nil, assignee_filter)
  end

  defp do_search(jql, start_at, assignee_filter) when is_binary(jql) do
    search_request(jql, start_at)
    |> case do
      {:ok, body} ->
        with {:ok, issues, next_start_at} <- decode_search_response(body, assignee_filter) do
          case next_start_at do
            nil ->
              {:ok, issues}

            next_start ->
              with {:ok, next_issues} <- do_search(jql, next_start, assignee_filter) do
                {:ok, issues ++ next_issues}
              end
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_tracker_config(tracker) do
    cond do
      not is_binary(tracker.base_url) -> {:error, :missing_jira_base_url}
      not is_binary(tracker.api_email) -> {:error, :missing_jira_api_email}
      not is_binary(tracker.api_key) -> {:error, :missing_jira_api_token}
      true -> :ok
    end
  end

  defp search_request(jql, start_at) do
    body =
      %{
        "jql" => jql,
        "fields" => @search_fields,
        "maxResults" => @search_page_size,
        "fieldsByKeys" => false
      }
      |> maybe_put("nextPageToken", start_at)

    log_jira_debug("search request path=search/jql jql=#{inspect(jql)} start_at=#{inspect(start_at)} body=#{inspect(body, limit: 20, printable_limit: 1000)}")

    with {:ok, response} <- request(:post, "search/jql", body, []),
         true <- response.status == 200 do
      log_jira_debug("search response status=200 summary=#{inspect(search_response_summary(response.body), limit: 20, printable_limit: 1000)}")
      {:ok, response.body}
    else
      {:error, reason} -> {:error, reason}
      {:ok, response} -> {:error, {:jira_api_status, response.status}}
      false -> {:error, {:jira_api_status, :search_failed}}
    end
  end

  @spec request(:get | :post | :put, String.t(), map() | nil, keyword()) :: request_result()
  def request(method, path, body, _opts \\ []) when method in [:get, :post, :put] and is_binary(path) do
    case request_headers() do
      {:ok, headers} ->
        url = request_url(Config.settings!().tracker.base_url, path)

        request_opts =
          [
            method: method,
            url: url,
            headers: headers,
            connect_options: [timeout: 30_000],
            receive_timeout: 30_000
          ]
          |> maybe_put_body(method, body)

        case Req.request(request_opts) do
          {:ok, response} ->
            log_jira_debug(
              "request method=#{method} url=#{url} status=#{response.status} response_summary=#{inspect(search_response_summary(response.body), limit: 20, printable_limit: 1000)}"
            )

            if response.status in 200..299 do
              {:ok, %{status: response.status, body: response.body}}
            else
              Logger.error("Jira request failed status=#{response.status} path=#{path} body=#{summarize_error_body(response.body)}")
              {:ok, %{status: response.status, body: response.body}}
            end

          {:error, reason} ->
            Logger.error("Jira request failed path=#{path}: #{inspect(reason)}")
            {:error, {:jira_api_request, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_headers do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.api_email) ->
        {:error, :missing_jira_api_email}

      not is_binary(tracker.api_key) ->
        {:error, :missing_jira_api_token}

      true ->
        encoded =
          "#{tracker.api_email}:#{tracker.api_key}"
          |> Base.encode64()

        {:ok,
         [
           {"authorization", "Basic " <> encoded},
           {"accept", "application/json"},
           {"content-type", "application/json"}
         ]}
    end
  end

  defp decode_search_response(%{"issues" => issues} = body, assignee_filter) when is_list(issues) do
    normalized =
      issues
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)

    next_start_at =
      cond do
        Map.get(body, "isLast") == true ->
          nil

        is_binary(Map.get(body, "nextPageToken")) and Map.get(body, "nextPageToken") != "" ->
          Map.get(body, "nextPageToken")

        true ->
          nil
      end

    {:ok, normalized, next_start_at}
  end

  defp decode_search_response(_body, _assignee_filter), do: {:error, :jira_unknown_payload}

  defp normalize_issue(%{"id" => _id, "key" => key, "fields" => fields}, assignee_filter)
       when is_binary(key) and is_map(fields) do
    assignee = Map.get(fields, "assignee")
    routed_to_worker = assigned_to_worker?(assignee, assignee_filter) and not epic_parent?(fields["parent"])

    %Issue{
      id: key,
      identifier: key,
      title: fields["summary"],
      description: extract_description(fields["description"]),
      priority: parse_priority(get_in(fields, ["priority", "name"])),
      state: get_in(fields, ["status", "name"]),
      branch_name: nil,
      url: issue_browse_url(key),
      assignee_id: assignee_match_value(assignee),
      blocked_by: extract_blockers(fields),
      labels: extract_labels(fields["labels"]),
      assigned_to_worker: routed_to_worker,
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp extract_description(description) when is_binary(description), do: description

  defp extract_description(%{"content" => content}) when is_list(content) do
    content
    |> flatten_adf_text()
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp extract_description(_description), do: nil

  defp flatten_adf_text(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        [text]

      %{"content" => nested} when is_list(nested) ->
        text = flatten_adf_text(nested) |> Enum.join("")

        case text do
          "" -> []
          value -> [value]
        end

      _ ->
        []
    end)
  end

  defp flatten_adf_text(_nodes), do: []

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_labels), do: []

  defp extract_blockers(%{"issuelinks" => issue_links}) when is_list(issue_links) do
    Enum.flat_map(issue_links, fn
      %{"type" => type, "inwardIssue" => issue} when is_map(type) and is_map(issue) ->
        if blocker_link_type?(type) do
          [
            %{
              id: issue["key"] || issue["id"],
              identifier: issue["key"],
              state: get_in(issue, ["fields", "status", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_fields), do: []

  defp epic_parent?(%{"fields" => %{"issuetype" => %{"name" => name}}}) when is_binary(name) do
    String.trim(name) |> String.downcase() == "epic"
  end

  defp epic_parent?(_parent), do: false

  defp blocker_link_type?(type) when is_map(type) do
    inward = type["inward"] |> to_string_or_empty() |> String.downcase()
    name = type["name"] |> to_string_or_empty() |> String.downcase()

    String.contains?(inward, "blocked by") or name == "blocks"
  end

  defp assignee_match_value(%{} = assignee) do
    Enum.find_value(
      [assignee["accountId"], assignee["emailAddress"], assignee["displayName"]],
      &normalize_assignee_match_value/1
    )
  end

  defp assignee_match_value(_assignee), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    case assignee_match_candidates(assignee) do
      [] -> false
      candidates -> Enum.any?(candidates, &MapSet.member?(match_values, &1))
    end
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_match_candidates(%{} = assignee) do
    [assignee["accountId"], assignee["emailAddress"], assignee["displayName"]]
    |> Enum.map(&normalize_assignee_match_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp routing_assignee_filter do
    build_assignee_filter(Config.settings!().tracker.assignee)
  end

  defp build_assignee_filter(nil), do: {:ok, nil}

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil -> {:ok, nil}
      "me" -> resolve_current_user_assignee_filter()
      normalized -> {:ok, %{match_values: MapSet.new([normalized])}}
    end
  end

  defp build_assignee_filter(_assignee), do: {:ok, nil}

  defp build_assignee_filter_for_test(nil), do: nil

  defp build_assignee_filter_for_test(assignee) do
    case build_assignee_filter(assignee) do
      {:ok, filter} -> filter
      _ -> nil
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> String.downcase(normalized)
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp resolve_current_user_assignee_filter do
    with {:ok, response} <- request(:get, "myself", nil, []),
         true <- response.status == 200,
         candidates when is_list(candidates) <- current_user_match_candidates(response.body),
         false <- candidates == [] do
      {:ok, %{match_values: MapSet.new(candidates)}}
    else
      false -> {:error, :missing_jira_viewer_identity}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_jira_viewer_identity}
    end
  end

  defp current_user_match_candidates(%{} = body) do
    [body["accountId"], body["emailAddress"], body["displayName"]]
    |> Enum.map(&normalize_assignee_match_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp current_user_match_candidates(_body), do: []

  defp build_state_jql(state_names) do
    state_clause =
      state_names
      |> Enum.map(&quote_jql_string/1)
      |> Enum.join(", ")

    base_jql() <> " AND status in (" <> state_clause <> ") ORDER BY priority DESC, created ASC"
  end

  defp build_issue_id_jql(ids) do
    key_list = ids |> Enum.map(&quote_jql_string/1) |> Enum.join(", ")
    "issuekey in (" <> key_list <> ")"
  end

  defp base_jql do
    tracker = Config.settings!().tracker

    cond do
      is_binary(tracker.jql) and String.trim(tracker.jql) != "" ->
        tracker.jql
        |> String.trim()
        |> strip_trailing_order_by()
        |> then(&("(" <> &1 <> ")"))

      is_binary(tracker.project_key) ->
        "project = " <> quote_jql_string(tracker.project_key)

      true ->
        ""
    end
  end

  defp resolve_transition_id(issue_id, state_name, request_fun) do
    with {:ok, response} <- request_fun.(:get, "issue/#{issue_id}/transitions", nil, []),
         true <- response.status == 200,
         transitions when is_list(transitions) <- Map.get(response.body, "transitions"),
         %{"id" => transition_id} = transition when is_binary(transition_id) <- find_transition(transitions, state_name) do
      log_resolved_transition(issue_id, state_name, transition)
      {:ok, transition_id}
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ ->
        log_missing_transition(issue_id, state_name, response_transition_names(request_fun, issue_id))
        {:error, :state_not_found}
    end
  end

  defp find_transition(transitions, state_name) when is_list(transitions) and is_binary(state_name) do
    wanted = normalize_state_name(state_name)

    Enum.find(transitions, fn
      %{} = transition ->
        transition_matches_state?(transition, wanted)

      _ ->
        false
    end)
  end

  defp find_transition(_transitions, _state_name), do: nil

  defp transition_matches_state?(%{} = transition, wanted) when is_binary(wanted) do
    action_name = transition["name"] |> to_string_or_empty() |> normalize_state_name()
    to_state_name = get_in(transition, ["to", "name"]) |> to_string_or_empty() |> normalize_state_name()

    action_name == wanted or to_state_name == wanted
  end

  defp log_resolved_transition(issue_id, state_name, transition)
       when is_binary(issue_id) and is_binary(state_name) and is_map(transition) do
    Logger.info(
      "Jira transition resolved issue_id=#{issue_id} requested_state=#{inspect(state_name)} transition_id=#{inspect(transition["id"])} transition=#{inspect(transition["name"])} -> #{inspect(get_in(transition, ["to", "name"]))}"
    )
  end

  defp log_missing_transition(issue_id, state_name, transition_names)
       when is_binary(issue_id) and is_binary(state_name) and is_list(transition_names) do
    Logger.warning(
      "Jira transition target not found issue_id=#{issue_id} requested_state=#{inspect(state_name)} available_transitions=#{inspect(transition_names)}"
    )
  end

  defp response_transition_names(request_fun, issue_id)
       when is_function(request_fun, 4) and is_binary(issue_id) do
    case request_fun.(:get, "issue/#{issue_id}/transitions", nil, []) do
      {:ok, %{status: 200, body: %{"transitions" => transitions}}} when is_list(transitions) ->
        transition_names(transitions)

      _ ->
        []
    end
  end

  defp transition_names(transitions) when is_list(transitions) do
    Enum.map(transitions, fn
      %{} = transition ->
        action_name = transition["name"] |> to_string_or_empty()
        to_state_name = get_in(transition, ["to", "name"]) |> to_string_or_empty()

        cond do
          action_name != "" and to_state_name != "" -> "#{action_name} -> #{to_state_name}"
          action_name != "" -> action_name
          to_state_name != "" -> to_state_name
          true -> inspect(transition)
        end

      transition -> inspect(transition)
    end)
  end

  defp sort_issues_by_requested_ids({:ok, issues}, ids) when is_list(issues) do
    order =
      ids
      |> Enum.with_index()
      |> Map.new()

    sorted =
      Enum.sort_by(issues, fn
        %Issue{id: id} -> Map.get(order, id, map_size(order))
        _ -> map_size(order)
      end)

    {:ok, sorted}
  end

  defp sort_issues_by_requested_ids(result, _ids), do: result

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  defp maybe_put_body(opts, method, nil) when method in [:post, :put], do: Keyword.put(opts, :json, %{})
  defp maybe_put_body(opts, method, body) when method in [:post, :put], do: Keyword.put(opts, :json, body)
  defp maybe_put_body(opts, _method, _body), do: opts

  defp issue_browse_url(key) when is_binary(key) do
    jira_site_base_url(Config.settings!().tracker.base_url) <> "/browse/" <> key
  end

  defp issue_browse_url(_key), do: nil

  defp jira_site_base_url(base_url) when is_binary(base_url) do
    base_url
    |> String.trim_trailing("/")
    |> String.replace(~r{/rest/api/\d+$}, "")
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp parse_priority(priority_name) when is_binary(priority_name) do
    case String.downcase(String.trim(priority_name)) do
      "highest" -> 1
      "high" -> 2
      "medium" -> 3
      "low" -> 4
      "lowest" -> 5
      _ -> nil
    end
  end

  defp parse_priority(_priority_name), do: nil

  defp normalize_state_names(state_names) when is_list(state_names) do
    state_names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_state_name(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state_name(_value), do: ""

  defp strip_trailing_order_by(jql) when is_binary(jql) do
    Regex.replace(~r/\s+order\s+by\s+.+$/i, jql, "")
  end

  defp quote_jql_string(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value), do: to_string(value)

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp search_response_summary(%{"issues" => issues} = body) when is_list(issues) do
    %{
      issue_count: length(issues),
      issue_keys: Enum.map(issues, &Map.get(&1, "key")) |> Enum.reject(&is_nil/1) |> Enum.take(10),
      is_last: Map.get(body, "isLast"),
      next_page_token: Map.get(body, "nextPageToken")
    }
  end

  defp search_response_summary(body) when is_map(body) do
    Map.take(body, ["errorMessages", "errors", "isLast", "nextPageToken"])
  end

  defp search_response_summary(body), do: body

  defp log_jira_debug(message) when is_binary(message) do
    if System.get_env("SYMPHONY_JIRA_DEBUG") in ["1", "true", "TRUE", "yes", "YES"] do
      Logger.warning("[jira-debug] " <> message)
      append_jira_debug_file("[jira-debug] " <> message)
    end
  end

  defp append_jira_debug_file(message) when is_binary(message) do
    path =
      System.get_env("SYMPHONY_JIRA_DEBUG_FILE") ||
        Path.join(File.cwd!(), "symphony-jira-debug-lines.log")

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write(path, "#{timestamp} #{message}\n", [:append])
  end
end
