defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.

  Sardine Run advertises a small surface of tools so an agent can update
  its assigned Traffic Control session without writing files directly.
  """

  @tool_name "sardine_run_session"

  @operations ~w(status heartbeat note link focus next_step)
  @statuses ~w(active blocked waiting review done archived)
  @waiting_kinds ~w(human ci review external other)

  @tool_spec %{
    "name" => @tool_name,
    "description" =>
      "Update the assigned Traffic Control session for this Sardine Run agent. " <>
        "Use to change status, record waiting state, append notes, add links, " <>
        "or send a heartbeat.",
    "parameters" => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["operation", "session_id"],
      "properties" => %{
        "operation" => %{
          "type" => "string",
          "enum" => @operations,
          "description" =>
            "Which session field group to update: status, heartbeat, note, link, focus, or next_step."
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Traffic Control session ID owning the session.yaml to update."
        },
        "status" => %{
          "type" => "string",
          "enum" => @statuses,
          "description" => "Required when operation=status. New session lifecycle state."
        },
        "waiting_kind" => %{
          "type" => "string",
          "enum" => @waiting_kinds,
          "description" =>
            "Optional, only meaningful when status=waiting. Why the session is paused."
        },
        "waiting_note" => %{
          "type" => "string",
          "description" => "Optional human-readable note describing the waiting reason."
        },
        "body" => %{
          "type" => "string",
          "description" => "Required when operation=note. Markdown body to append to notes.md."
        },
        "label" => %{
          "type" => "string",
          "description" => "Required when operation=link. Display label for the link entry."
        },
        "link_kind" => %{
          "type" => "string",
          "description" =>
            "Required when operation=link. Link category (e.g. jira, slack, pr, doc, repo, other)."
        },
        "url" => %{
          "type" => "string",
          "description" => "Required when operation=link. URL to record in links.yaml."
        },
        "last_event" => %{
          "type" => "string",
          "description" => "Optional. Last runtime event identifier sent with heartbeat."
        },
        "last_message" => %{
          "type" => "string",
          "description" => "Optional. Last runtime status message sent with heartbeat."
        },
        "last_error" => %{
          "type" => "string",
          "description" => "Optional. Last runtime error message sent with heartbeat."
        },
        "input_tokens" => %{
          "type" => "integer",
          "description" => "Optional. Cumulative input token count to record."
        },
        "output_tokens" => %{
          "type" => "integer",
          "description" => "Optional. Cumulative output token count to record."
        },
        "total_tokens" => %{
          "type" => "integer",
          "description" => "Optional. Cumulative total token count to record."
        },
        "value" => %{
          "type" => "string",
          "description" =>
            "Used by operation=focus and operation=next_step to set the field. " <>
              "Empty string clears the field."
        }
      }
    }
  }

  @spec tool_specs() :: [map()]
  def tool_specs, do: [@tool_spec]

  def execute(tool, arguments, opts \\ [])

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@tool_name, arguments, _opts) when is_map(arguments) do
    handle_session_tool(arguments)
  end

  def execute(@tool_name, _arguments, _opts) do
    validation_failure(%{
      "message" => "Arguments must be an object."
    })
  end

  def execute(tool, _arguments, _opts) do
    failure(%{
      "error" => %{
        "kind" => "unknown_tool",
        "message" => "Unknown tool #{inspect(tool)}.",
        "supportedTools" => Enum.map(tool_specs(), & &1["name"])
      }
    })
  end

  defp handle_session_tool(args) do
    with {:ok, _session_id} <- require_string(args, "session_id"),
         {:ok, _operation} <- require_enum(args, "operation", @operations) do
      validation_failure(%{
        "message" => "sardine_run_session operations are not yet implemented."
      })
    else
      {:error, reason} -> validation_failure(reason)
    end
  end

  defp require_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, %{"field" => key, "message" => "#{key} is required and must be a non-empty string."}}
    end
  end

  defp require_enum(args, key, allowed) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        if value in allowed do
          {:ok, value}
        else
          {:error,
           %{
             "field" => key,
             "message" => "#{key} must be one of: #{Enum.join(allowed, ", ")}.",
             "allowed" => allowed
           }}
        end

      _ ->
        {:error, %{"field" => key, "message" => "#{key} is required and must be a string."}}
    end
  end

  defp validation_failure(reason) do
    failure(%{"error" => Map.put(reason, "kind", "invalid_arguments")})
  end

  defp failure(payload) do
    output = encode_payload(payload)

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [
        %{"type" => "inputText", "text" => output}
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)
end
