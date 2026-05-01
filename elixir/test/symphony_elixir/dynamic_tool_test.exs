defmodule SymphonyElixir.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs returns no tools while sardine-run tools are pending" do
    assert DynamicTool.tool_specs() == []
  end

  test "execute returns a structured failure for any tool name" do
    response = DynamicTool.execute("anything", %{"foo" => "bar"})

    assert %{
             "success" => false,
             "output" => output,
             "contentItems" => [%{"type" => "inputText", "text" => text}]
           } = response

    assert output == text
    decoded = Jason.decode!(output)

    assert decoded == %{
             "error" => %{
               "message" => "No dynamic tools are currently advertised.",
               "supportedTools" => []
             }
           }
  end

  test "execute tolerates non-encodable arguments" do
    response = DynamicTool.execute(nil, :unexpected)
    assert %{"success" => false} = response
  end
end
