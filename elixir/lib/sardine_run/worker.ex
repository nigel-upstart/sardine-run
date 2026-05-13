defmodule SardineRun.Worker do
  @moduledoc """
  Behaviour implemented by coding-agent worker backends (Codex, Claude, etc.).

  An agent run starts a worker session, drives one or more turns inside it, and
  then stops the session. The orchestrator's sampler binds one of these
  implementations to each dispatch via `SardineRun.Worker.Sampler.pick/2`.

  Implementations MUST return an opaque session value from `start_session/2`;
  the orchestrator never inspects its shape and just round-trips it through
  `run_turn/4` and `stop_session/1`.
  """

  @typedoc "Stable identifier for the worker backend (e.g. `:codex`, `:claude`)."
  @type kind :: atom()

  @typedoc "Opaque per-session state; only the worker module interprets it."
  @type session :: term()

  @typedoc "Tracker issue passed through `SardineRun.AgentRunner`."
  @type issue :: map()

  @doc """
  Returns a short identifier for this worker backend (e.g. `:codex`, `:claude`).

  Used for logging, dashboard badges, and the `worker_kind` field written to
  the Traffic Control session runtime block.
  """
  @callback kind() :: kind()

  @doc """
  Starts a worker session inside the given workspace path and returns an
  opaque session handle. `opts` are implementation-defined; the agent runner
  forwards `:worker_host`.
  """
  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Runs one turn against an existing session. `opts` carry callbacks such as
  `:on_message`; the implementation forwards them to the underlying transport.

  The return shape mirrors `SardineRun.Codex.AppServer.run_turn/4`: `{:ok,
  result_map}` on success, `{:error, reason}` on failure. The `result_map`
  SHOULD include `:session_id`, `:thread_id`, and `:turn_id` so downstream
  presenters can render them.
  """
  @callback run_turn(session(), prompt :: String.t(), issue(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Terminates the worker session. MUST be idempotent and tolerate a session
  that already exited; called from a `try/after` block by the agent runner.
  """
  @callback stop_session(session()) :: :ok
end
