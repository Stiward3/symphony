defmodule SymphonyElixir.JiraMockFixtureTest do
  use ExUnit.Case

  @fixture_path Path.expand("../fixtures/jira/rdsp_219_create_issue_payload.json", __DIR__)

  test "RDSP-219 Jira create issue mock is valid and preserves the ticket context" do
    fixture = File.read!(@fixture_path)
    assert {:ok, payload} = Jason.decode(fixture)

    assert get_in(payload, ["fields", "project", "key"]) == "RDSP"
    assert get_in(payload, ["fields", "summary"]) == "Symphony Build test"
    assert get_in(payload, ["fields", "issuetype", "name"]) == "Task"
    assert get_in(payload, ["fields", "priority", "name"]) == "Medium"

    assert get_in(payload, ["fields", "labels"]) == [
             "symphony",
             "build-test",
             "jira-api-mock"
           ]

    assert get_in(payload, ["fields", "description", "type"]) == "doc"
    assert get_in(payload, ["fields", "description", "version"]) == 1

    assert get_in(payload, ["fields", "description", "content"]) == [
             %{
               "type" => "paragraph",
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Build a Json mock that will be inserted in Jira via the api"
                 }
               ]
             }
           ]
  end
end
