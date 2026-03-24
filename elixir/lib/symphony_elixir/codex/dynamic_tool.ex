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

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @jira_issue_update_tool ->
        execute_jira_issue_update(arguments, opts)

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

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
