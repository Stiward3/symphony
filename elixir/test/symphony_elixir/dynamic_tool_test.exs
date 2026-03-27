defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "tool_specs advertises the jira_issue_update contract when jira is configured" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "comment" => _,
                   "issueId" => _,
                   "state" => _
                 },
                 "required" => ["issueId"],
                 "type" => "object"
               },
               "name" => "jira_issue_update"
             },
             %{
               "description" => github_description,
               "inputSchema" => %{
                 "properties" => %{
                   "commitMessage" => _,
                   "paths" => _,
                   "prBody" => _,
                   "prTitle" => _
                 },
                 "required" => ["commitMessage", "prTitle"],
                 "type" => "object"
               },
               "name" => "github_delivery"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Jira"
    assert github_description =~ "GitHub"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "jira_issue_update can create a comment and transition state" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")
    test_pid = self()

    response =
      DynamicTool.execute(
        "jira_issue_update",
        %{
          "issueId" => "PRJ-123",
          "comment" => "Workpad updated",
          "state" => "Code Review"
        },
        tracker_create_comment: fn issue_id, body ->
          send(test_pid, {:tracker_create_comment, issue_id, body})
          :ok
        end,
        tracker_update_issue_state: fn issue_id, state_name ->
          send(test_pid, {:tracker_update_issue_state, issue_id, state_name})
          :ok
        end
      )

    assert_received {:tracker_create_comment, "PRJ-123", "Workpad updated"}
    assert_received {:tracker_update_issue_state, "PRJ-123", "Code Review"}
    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "commentCreated" => true,
             "issueId" => "PRJ-123",
             "stateUpdated" => "Code Review"
           }
  end

  test "jira_issue_update validates required action fields" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    missing_action =
      DynamicTool.execute(
        "jira_issue_update",
        %{"issueId" => "PRJ-123"},
        tracker_create_comment: fn _issue_id, _body -> flunk("comment should not be called") end,
        tracker_update_issue_state: fn _issue_id, _state -> flunk("state update should not be called") end
      )

    assert missing_action["success"] == false

    assert Jason.decode!(missing_action["output"]) == %{
             "error" => %{
               "message" => "`jira_issue_update` requires at least one of `comment` or `state`."
             }
           }
  end

  test "jira_issue_update reports tracker failures" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    comment_failure =
      DynamicTool.execute(
        "jira_issue_update",
        %{"issueId" => "PRJ-123", "comment" => "hello"},
        tracker_create_comment: fn _issue_id, _body -> {:error, :forbidden} end
      )

    assert comment_failure["success"] == false

    assert Jason.decode!(comment_failure["output"]) == %{
             "error" => %{
               "message" => "Jira comment creation failed.",
               "reason" => ":forbidden"
             }
           }

    state_failure =
      DynamicTool.execute(
        "jira_issue_update",
        %{"issueId" => "PRJ-123", "state" => "Done"},
        tracker_update_issue_state: fn _issue_id, _state -> {:error, :state_not_found} end
      )

    assert state_failure["success"] == false

    assert Jason.decode!(state_failure["output"]) == %{
             "error" => %{
               "message" => "Jira state transition failed.",
               "reason" => ":state_not_found"
             }
           }
  end

  test "github_delivery commits, pushes, and creates a pull request from the host workspace" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")
    test_pid = self()
    workspace = Path.join(System.tmp_dir!(), "github-delivery-test-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(workspace)

    response =
      DynamicTool.execute(
        "github_delivery",
        %{
          "commitMessage" => "feat(jira): add fixture\n\nSummary:\n- add fixture\n",
          "prTitle" => "Add Jira fixture",
          "prBody" => "## Summary\n- add fixture",
          "paths" => ["elixir/test/fixtures/jira/rdsp_219_create_issue_payload.json"]
        },
        workspace: workspace,
        executable_finder: fn
          "git" -> "/usr/bin/git"
          "gh" -> "/usr/bin/gh"
          _ -> nil
        end,
        command_runner: fn command, args, opts ->
          send(test_pid, {:command_runner_called, command, args, opts})

          case {command, args} do
            {"git", ["add", "--", "elixir/test/fixtures/jira/rdsp_219_create_issue_payload.json"]} -> {"", 0}
            {"git", ["status", "--porcelain"]} -> {"A  elixir/test/fixtures/jira/rdsp_219_create_issue_payload.json\n", 0}
            {"git", ["commit", "-F", _commit_file]} -> {"[codex/RDSP-219 abc1234] Add Jira fixture\n", 0}
            {"git", ["rev-parse", "HEAD"]} -> {"abc1234def5678\n", 0}
            {"git", ["branch", "--show-current"]} -> {"codex/RDSP-219\n", 0}
            {"git", ["push", "-u", "origin", "HEAD"]} -> {"remote ok\n", 0}
            {"gh", ["pr", "view", "--json", "state,url"]} -> {~s({"state":"OPEN","url":"https://github.com/Stiward3/symphony/pull/219"}), 0}
            {"gh", ["pr", "edit", "--title", "Add Jira fixture", "--body", "## Summary\n- add fixture"]} -> {"updated\n", 0}
            {"git", ["remote", "get-url", "origin"]} -> {"https://github.com/Stiward3/symphony.git\n", 0}
            other -> flunk("unexpected command: #{inspect(other)}")
          end
        end
      )

    assert_received {:command_runner_called, "git", ["add", "--", "elixir/test/fixtures/jira/rdsp_219_create_issue_payload.json"], [cd: ^workspace, stderr_to_stdout: true]}
    assert_received {:command_runner_called, "git", ["push", "-u", "origin", "HEAD"], [cd: ^workspace, stderr_to_stdout: true]}
    assert_received {:command_runner_called, "gh", ["pr", "edit", "--title", "Add Jira fixture", "--body", "## Summary\n- add fixture"], [cd: ^workspace, stderr_to_stdout: true]}

    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "branch" => "codex/RDSP-219",
             "commitSha" => "abc1234def5678",
             "pr" => %{
               "action" => "updated",
               "url" => "https://github.com/Stiward3/symphony/pull/219"
             },
             "repoUrl" => "https://github.com/Stiward3/symphony.git"
           }
  end

  test "github_delivery reports missing host executables clearly" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    response =
      DynamicTool.execute(
        "github_delivery",
        %{
          "commitMessage" => "feat: test",
          "prTitle" => "Test PR"
        },
        workspace: "/tmp/workspace",
        executable_finder: fn
          "git" -> "/usr/bin/git"
          "gh" -> nil
        end,
        command_runner: fn _command, _args, _opts ->
          flunk("command runner should not be called when gh is missing")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`github_delivery` requires `gh` to be available in Symphony's host environment."
             }
           }
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
