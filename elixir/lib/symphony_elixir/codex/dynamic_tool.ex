defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.

  Sardine Run advertises a small surface of tools so an agent can update
  its assigned Traffic Control session without writing files directly.
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(_tool, _arguments, _opts \\ []) do
    failure_response(%{
      "error" => %{
        "message" => "No dynamic tools are currently advertised.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  @spec tool_specs() :: [map()]
  def tool_specs, do: []

  defp failure_response(payload) do
    output = encode_payload(payload)

    %{
      "success" => false,
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

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
