defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  describe "tool_specs/0" do
    test "advertises one sardine_run_session tool with the expected schema" do
      assert [tool] = DynamicTool.tool_specs()
      assert tool["name"] == "sardine_run_session"
      assert is_binary(tool["description"])
      assert String.length(tool["description"]) > 0

      params = tool["parameters"]
      assert params["type"] == "object"
      props = params["properties"]

      assert props["operation"]["enum"] == [
               "status",
               "heartbeat",
               "note",
               "link",
               "focus",
               "next_step"
             ]

      assert props["session_id"]["type"] == "string"

      assert props["status"]["enum"] == [
               "active",
               "blocked",
               "waiting",
               "review",
               "done",
               "archived"
             ]

      assert props["waiting_kind"]["enum"] == [
               "human",
               "ci",
               "review",
               "external",
               "other"
             ]

      assert "operation" in params["required"]
      assert "session_id" in params["required"]

      for key <- ~w(waiting_note body label link_kind url last_event last_message last_error value) do
        assert props[key]["type"] == "string", "expected #{key} to be string typed"
      end

      for key <- ~w(input_tokens output_tokens total_tokens) do
        assert props[key]["type"] == "integer", "expected #{key} to be integer typed"
      end
    end
  end

  describe "execute/3 validation" do
    test "unknown tool returns structured failure" do
      response = DynamicTool.execute("not_a_tool", %{})
      assert %{"success" => false, "output" => output} = response
      assert output =~ "not_a_tool" or output =~ "unknown"
    end

    test "missing session_id returns structured failure" do
      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "status",
          "status" => "done"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "session_id"
    end

    test "unknown operation returns structured failure" do
      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "frobnicate",
          "session_id" => "abc"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "frobnicate" or output =~ "operation"
    end

    test "all responses include matched contentItems" do
      response = DynamicTool.execute(nil, :unexpected)
      assert %{"success" => false, "output" => output, "contentItems" => items} = response
      assert is_list(items)
      assert Enum.any?(items, &(&1["text"] == output))
    end
  end
end
