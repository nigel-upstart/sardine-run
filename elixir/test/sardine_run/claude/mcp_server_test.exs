defmodule SardineRun.Claude.MCPServerTest do
  use SardineRun.TestSupport

  alias SardineRun.Claude.MCPServer

  setup do
    state_repo = make_state_repo!()
    previous_env = System.get_env("TRAFFIC_CONTROL_STATE_REPO")
    System.delete_env("TRAFFIC_CONTROL_STATE_REPO")

    on_exit(fn ->
      restore_env("TRAFFIC_CONTROL_STATE_REPO", previous_env)
      File.rm_rf!(state_repo)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "traffic_control",
      tracker_state_repo: state_repo
    )

    {:ok, state_repo: state_repo}
  end

  test "initialize returns server capabilities for tools" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-06-18"}
    }

    response = MCPServer.handle_message(request, [])

    assert response["id"] == 1
    assert is_map(response["result"]["capabilities"]["tools"])
    assert is_binary(response["result"]["serverInfo"]["name"])
  end

  test "tools/list advertises the sardine_run_session tool" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/list"
    }

    response = MCPServer.handle_message(request, [])

    assert response["id"] == 2
    assert [tool] = response["result"]["tools"]
    assert tool["name"] == "sardine_run_session"
    assert is_binary(tool["description"])
    assert tool["inputSchema"]["type"] == "object"
  end

  test "notifications/initialized produces no reply" do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    }

    assert MCPServer.handle_message(request, []) == :no_reply
  end

  test "tools/call delegates to DynamicTool.execute and writes session.yaml",
       %{state_repo: state_repo} do
    session_id = "MT-CLAUDE-1"
    write_session_yaml!(state_repo, session_id, status: "active")

    request = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{
        "name" => "sardine_run_session",
        "arguments" => %{
          "operation" => "status",
          "session_id" => session_id,
          "status" => "review"
        }
      }
    }

    response = MCPServer.handle_message(request, [])

    assert response["id"] == 3
    assert %{"content" => [%{"type" => "text", "text" => text}]} = response["result"]
    assert response["result"]["isError"] == false
    assert text =~ ~s("success": true)
    assert text =~ session_id

    session_path = Path.join([state_repo, "sessions", session_id, "session.yaml"])
    assert File.read!(session_path) =~ "status: review"
  end

  test "tools/call returns isError=true when the dynamic tool rejects arguments" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "tools/call",
      "params" => %{
        "name" => "sardine_run_session",
        "arguments" => %{"operation" => "status"}
      }
    }

    response = MCPServer.handle_message(request, [])

    assert response["id"] == 4
    assert response["result"]["isError"] == true
    assert [%{"text" => text}] = response["result"]["content"]
    assert text =~ "invalid_arguments"
  end

  test "unknown method returns JSON-RPC -32601" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 5,
      "method" => "totally/unknown"
    }

    response = MCPServer.handle_message(request, [])

    assert response["id"] == 5
    assert response["error"]["code"] == -32_601
    assert response["error"]["message"] == "Method not found"
  end
end
