defmodule SardineRun.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.

  Sardine Run advertises a small surface of tools so an agent can update
  its assigned Traffic Control session without writing files directly.
  """

  alias SardineRun.Review
  alias SardineRun.TrafficControl.SessionWriter

  @tool_name "sardine_run_session"

  @operations ~w(
    status heartbeat note link focus next_step git_push
    list_review_comments reply_to_comment resolve_thread request_human_help
  )
  @statuses ~w(active blocked waiting review done archived)
  @waiting_kinds ~w(human ci review external other)

  @tool_spec %{
    "name" => @tool_name,
    "description" =>
      "Update the assigned Traffic Control session for this Sardine Run agent. " <>
        "Use to change status, record waiting state, append notes, add links, " <>
        "send a heartbeat, or push a git branch via the orchestrator (git_push). " <>
        "Reviewer-only operations (list_review_comments, reply_to_comment, " <>
        "resolve_thread, request_human_help) are used by the :reviewer worker " <>
        "to read and address pending PR review feedback. " <>
        "git_push runs on the host outside the sandbox, so it works even when " <>
        "the agent's network access is disabled.",
    "inputSchema" => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["operation", "session_id"],
      "properties" => %{
        "operation" => %{
          "type" => "string",
          "enum" => @operations,
          "description" => "Which session field group to update: status, heartbeat, note, link, focus, or next_step."
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
          "description" => "Optional, only meaningful when status=waiting. Why the session is paused."
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
          "description" => "Required when operation=link. Link category (e.g. jira, slack, pr, doc, repo, other)."
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
        },
        "branch" => %{
          "type" => "string",
          "description" => "Required when operation=git_push. Local branch name to push (e.g. feat/my-feature)."
        },
        "remote" => %{
          "type" => "string",
          "description" => "Optional when operation=git_push. Remote name to push to (default: origin)."
        },
        "comment_id" => %{
          "type" => "integer",
          "description" => "Required when operation=reply_to_comment. REST comment ID (integer) to thread the reply under."
        },
        "thread_id" => %{
          "type" => "string",
          "description" => "Required when operation=resolve_thread. GraphQL node ID of the review thread (e.g. 'PRRT_kwDOKqpK0M5vt_nf'), not the REST comment ID."
        },
        "reason" => %{
          "type" => "string",
          "description" => "Required when operation=resolve_thread. Short rationale recorded for caller bookkeeping. The substantive reply belongs in the preceding reply_to_comment."
        }
      }
    }
  }

  @spec tool_specs() :: [map()]
  def tool_specs, do: [@tool_spec]

  @doc """
  Returns the single tool spec map (same entry that `tool_specs/0` wraps in a list).

  Exposed so transports that advertise tools individually — for example the
  stdio MCP server used by `SardineRun.Claude.AppServer` — can reuse the exact
  schema without duplicating it.
  """
  @spec tool_spec() :: map()
  def tool_spec, do: @tool_spec

  @doc """
  Returns the canonical tool name (`"sardine_run_session"`).

  Public so MCP/tool transports outside this module can match incoming tool
  calls without hard-coding the string.
  """
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  def execute(tool, arguments, opts \\ [])

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@tool_name, arguments, opts) when is_map(arguments) do
    handle_session_tool(arguments, opts)
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

  defp handle_session_tool(args, opts) do
    with {:ok, session_id} <- require_string(args, "session_id"),
         {:ok, operation} <- require_enum(args, "operation", @operations) do
      dispatch(operation, session_id, args, opts)
    else
      {:error, reason} -> validation_failure(reason)
    end
  end

  defp dispatch("status", session_id, args, _opts) do
    case require_enum(args, "status", @statuses) do
      {:ok, status} ->
        waiting =
          if status == "waiting" do
            %{
              "kind" => Map.get(args, "waiting_kind") || "other",
              "note" => Map.get(args, "waiting_note")
            }
          else
            nil
          end

        case SessionWriter.update_status(session_id, status, waiting) do
          :ok -> success(%{"session_id" => session_id, "status" => status})
          {:error, reason} -> writer_failure(reason)
        end

      {:error, reason} ->
        validation_failure(reason)
    end
  end

  defp dispatch("heartbeat", session_id, args, _opts) do
    runtime =
      %{
        "last_event" => Map.get(args, "last_event"),
        "last_message" => Map.get(args, "last_message"),
        "last_error" => Map.get(args, "last_error"),
        "input_tokens" => Map.get(args, "input_tokens"),
        "output_tokens" => Map.get(args, "output_tokens"),
        "total_tokens" => Map.get(args, "total_tokens")
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case SessionWriter.update_heartbeat(session_id, runtime) do
      :ok -> success(%{"session_id" => session_id, "operation" => "heartbeat"})
      {:error, reason} -> writer_failure(reason)
    end
  end

  defp dispatch("note", session_id, args, _opts) do
    case require_string(args, "body") do
      {:ok, body} ->
        case SessionWriter.append_note(session_id, body) do
          :ok -> success(%{"session_id" => session_id, "operation" => "note"})
          {:error, reason} -> writer_failure(reason)
        end

      {:error, reason} ->
        validation_failure(reason)
    end
  end

  defp dispatch("link", session_id, args, _opts) do
    with {:ok, label} <- require_string(args, "label"),
         {:ok, kind} <- require_string(args, "link_kind"),
         {:ok, url} <- require_string(args, "url") do
      case SessionWriter.append_link(session_id, %{
             "label" => label,
             "kind" => kind,
             "url" => url
           }) do
        :ok -> success(%{"session_id" => session_id, "operation" => "link"})
        {:error, reason} -> writer_failure(reason)
      end
    else
      {:error, reason} -> validation_failure(reason)
    end
  end

  defp dispatch("focus", session_id, args, _opts) do
    case SessionWriter.update_field(session_id, "focus", Map.get(args, "value")) do
      :ok -> success(%{"session_id" => session_id, "operation" => "focus"})
      {:error, reason} -> writer_failure(reason)
    end
  end

  defp dispatch("next_step", session_id, args, _opts) do
    case SessionWriter.update_field(session_id, "next_step", Map.get(args, "value")) do
      :ok -> success(%{"session_id" => session_id, "operation" => "next_step"})
      {:error, reason} -> writer_failure(reason)
    end
  end

  defp dispatch("git_push", session_id, args, opts) do
    workspace = Keyword.get(opts, :workspace)
    remote = Map.get(args, "remote", "origin")

    with {:ok, branch} <- require_string(args, "branch"),
         :ok <- validate_git_ref(branch),
         :ok <- validate_git_ref(remote) do
      case run_git_push(workspace, remote, branch) do
        {:ok, output} ->
          success(%{"session_id" => session_id, "output" => output})

        {:error, :no_workspace} ->
          validation_failure(%{
            "field" => "workspace",
            "message" => "workspace is not available for git_push"
          })

        {:error, {:git_push_failed, status, output}} ->
          failure(%{
            "error" => %{
              "kind" => "git_push_failed",
              "message" => "git push exited #{status}: #{output}"
            }
          })
      end
    else
      {:error, reason} -> validation_failure(reason)
    end
  end

  defp dispatch("list_review_comments", session_id, _args, _opts) do
    case SessionWriter.read_pending_feedback(session_id) do
      {:ok, feedback} ->
        success(%{
          "session_id" => session_id,
          "operation" => "list_review_comments",
          "feedback" => feedback
        })

      {:error, reason} ->
        writer_failure(reason)
    end
  end

  defp dispatch("reply_to_comment", session_id, args, _opts) do
    with {:ok, comment_id} <- require_integer(args, "comment_id"),
         {:ok, body} <- require_string(args, "body"),
         {:ok, url} <- lookup_pr_url(session_id),
         {:ok, pr_ref} <- parse_pr_url(url) do
      case Review.GitHub.reply_to_comment(pr_ref, comment_id, body) do
        {:ok, _result} ->
          success(%{
            "session_id" => session_id,
            "operation" => "reply_to_comment",
            "comment_id" => comment_id
          })

        {:error, reason} ->
          gh_failure(reason)
      end
    else
      {:error, %{} = validation} -> validation_failure(validation)
      {:error, :no_pr_link} -> validation_failure(%{"field" => "session", "message" => "No link of kind=pr is recorded for this session."})
      {:error, :invalid_pr_url} -> validation_failure(%{"field" => "session", "message" => "Recorded PR link URL is not a github.com pull URL."})
      {:error, reason} -> writer_failure(reason)
    end
  end

  defp dispatch("resolve_thread", session_id, args, _opts) do
    with {:ok, thread_id} <- require_string(args, "thread_id"),
         {:ok, reason} <- require_string(args, "reason") do
      case Review.GitHub.resolve_thread(thread_id, reason) do
        {:ok, _result} ->
          success(%{
            "session_id" => session_id,
            "operation" => "resolve_thread",
            "thread_id" => thread_id
          })

        {:error, gh_reason} ->
          gh_failure(gh_reason)
      end
    else
      {:error, reason} -> validation_failure(reason)
    end
  end

  defp dispatch("request_human_help", session_id, args, _opts) do
    case require_string(args, "body") do
      {:ok, note} ->
        waiting = %{"kind" => "human", "note" => note}

        case SessionWriter.update_status(session_id, "waiting", waiting) do
          :ok ->
            success(%{
              "session_id" => session_id,
              "operation" => "request_human_help",
              "status" => "waiting"
            })

          {:error, reason} ->
            writer_failure(reason)
        end

      {:error, reason} ->
        validation_failure(reason)
    end
  end

  defp dispatch(operation, _session_id, _args, _opts) do
    validation_failure(%{
      "field" => "operation",
      "message" => "Unknown operation #{inspect(operation)}.",
      "allowed" => @operations
    })
  end

  defp lookup_pr_url(session_id) do
    SessionWriter.find_pr_url(session_id)
  end

  defp parse_pr_url(url), do: Review.GitHub.parse_pr_url(url)

  defp validate_git_ref(ref) when is_binary(ref) do
    cond do
      String.starts_with?(ref, "-") ->
        {:error, %{"message" => "git ref must not start with '-': #{inspect(ref)}"}}

      String.contains?(ref, "..") ->
        {:error, %{"message" => "git ref must not contain '..': #{inspect(ref)}"}}

      not String.match?(ref, ~r/^[a-zA-Z0-9][a-zA-Z0-9._\-\/]*$/) ->
        {:error, %{"message" => "git ref contains disallowed characters: #{inspect(ref)}"}}

      true ->
        :ok
    end
  end

  defp run_git_push(nil, _remote, _branch) do
    {:error, :no_workspace}
  end

  defp run_git_push(workspace, remote, branch) when is_binary(workspace) do
    case System.cmd("git", ["push", remote, branch],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_push_failed, status, String.trim(output)}}
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

  defp require_integer(args, key) do
    case Map.get(args, key) do
      value when is_integer(value) ->
        {:ok, value}

      _ ->
        {:error, %{"field" => key, "message" => "#{key} is required and must be an integer."}}
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

  defp writer_failure(reason) do
    failure(%{
      "error" => %{
        "kind" => "writer_error",
        "message" => format_writer_reason(reason)
      }
    })
  end

  defp gh_failure({:gh_failed, status, output}) do
    failure(%{
      "error" => %{
        "kind" => "gh_failed",
        "message" => "gh exited #{status}: #{output}"
      }
    })
  end

  defp gh_failure({:invalid_thread_id, thread_id}) do
    validation_failure(%{
      "field" => "thread_id",
      "message" => "thread_id must match /^[A-Za-z0-9_-]+$/: #{inspect(thread_id)}"
    })
  end

  defp format_writer_reason(:enoent), do: "session.yaml not found (enoent)."
  defp format_writer_reason(:state_repo_not_configured), do: "tracker.state_repo is not configured."
  defp format_writer_reason(reason), do: inspect(reason)

  defp success(payload) do
    output = encode_payload(Map.put(payload, "success", true))

    %{
      "success" => true,
      "output" => output,
      "contentItems" => [
        %{"type" => "inputText", "text" => output}
      ]
    }
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
