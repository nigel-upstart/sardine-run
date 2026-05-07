defmodule SardineRunWeb.SessionDetailLive do
  @moduledoc """
  Per-session drill-down view. Renders a single issue's live agent state
  (and, in later slices, workspace git log, filtered log tail, notes.md,
  and on-disk paths). The data comes from the orchestrator snapshot via
  `SardineRunWeb.SessionDetailPresenter`.
  """

  use Phoenix.LiveView, layout: {SardineRunWeb.Layouts, :app}

  alias SardineRunWeb.{Endpoint, ObservabilityPubSub, SessionDetailPresenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"issue_identifier" => raw_identifier}, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok,
     socket
     |> assign(:raw_identifier, raw_identifier)
     |> assign(:now, DateTime.utc_now())
     |> assign_payload()}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign_payload()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= case @result do %>
      <% {:error, _} -> %>
        <section class="dashboard-shell">
          <header class="hero-card">
            <div>
              <p class="eyebrow">Sardine Run · Session detail</p>
              <h1 class="hero-title">Session not active</h1>
              <p class="hero-copy">
                <code><%= @raw_identifier %></code> is not currently in the
                orchestrator snapshot. It may have completed, been cleaned
                up, or never existed.
              </p>
            </div>
          </header>

          <section class="section-card">
            <p class="section-copy">
              <a class="issue-link" href="/">← Back to dashboard</a>
            </p>
          </section>
        </section>
      <% {:ok, payload} -> %>
        <section class="dashboard-shell">
          <header class="hero-card">
            <div class="hero-grid">
              <div>
                <p class="eyebrow">Sardine Run · Session detail</p>
                <h1 class="hero-title">
                  <%= payload.identifier %>
                </h1>
                <p class="hero-copy">
                  <span class={status_badge_class(payload.status)}><%= payload.status %></span>
                  <%= if payload.header.worker_host do %>
                    · worker <span class="mono"><%= payload.header.worker_host %></span>
                  <% end %>
                  <%= if payload.header.workspace_path do %>
                    · workspace <span class="mono"><%= payload.header.workspace_path %></span>
                  <% end %>
                </p>
                <p class="section-copy">
                  <a class="issue-link" href="/">← Back to dashboard</a>
                </p>
              </div>
            </div>
          </header>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Live agent state</h2>
                <p class="section-copy">Latest snapshot from the orchestrator.</p>
              </div>
            </div>

            <dl class="metric-grid">
              <div class="metric-card">
                <dt class="metric-label">State</dt>
                <dd class="metric-value"><%= payload.live_state.state || "n/a" %></dd>
              </div>
              <div class="metric-card">
                <dt class="metric-label">Session</dt>
                <dd class="metric-value mono"><%= payload.live_state.session_id || "n/a" %></dd>
              </div>
              <div class="metric-card">
                <dt class="metric-label">Turns</dt>
                <dd class="metric-value numeric"><%= payload.live_state.turn_count %></dd>
              </div>
              <div class="metric-card">
                <dt class="metric-label">Started at</dt>
                <dd class="metric-value mono numeric"><%= payload.live_state.started_at || "n/a" %></dd>
              </div>
            </dl>

            <dl class="metric-grid">
              <div class="metric-card">
                <dt class="metric-label">Last event</dt>
                <dd class="metric-value">
                  <%= payload.live_state.last_message || (payload.live_state.last_event && to_string(payload.live_state.last_event)) || "n/a" %>
                  <span class="muted event-meta">
                    <%= payload.live_state.last_event || "" %>
                    <%= if payload.live_state.last_event_at do %>
                      · <span class="mono numeric"><%= payload.live_state.last_event_at %></span>
                    <% end %>
                  </span>
                </dd>
              </div>
              <div class="metric-card">
                <dt class="metric-label">Tokens</dt>
                <dd class="metric-value numeric">
                  Total: <%= format_int(payload.live_state.tokens.total_tokens) %>
                  <span class="muted">
                    In <%= format_int(payload.live_state.tokens.input_tokens) %> ·
                    Out <%= format_int(payload.live_state.tokens.output_tokens) %>
                  </span>
                </dd>
              </div>
            </dl>

            <%= if payload.live_state.retry do %>
              <div class="section-card">
                <h3 class="section-title">Retry</h3>
                <p class="section-copy">
                  Attempt <%= payload.live_state.retry.attempt %>
                  <%= if payload.live_state.retry.due_at do %>
                    · due at <span class="mono numeric"><%= payload.live_state.retry.due_at %></span>
                  <% end %>
                </p>
                <%= if payload.live_state.last_error do %>
                  <pre class="code-panel"><%= payload.live_state.last_error %></pre>
                <% end %>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Workspace git log</h2>
                <p class="section-copy">Last <%= length(payload.git_log.lines) %> commits in the agent's workspace.</p>
              </div>
            </div>

            <%= case payload.git_log.status do %>
              <% :ok -> %>
                <pre class="code-panel"><%= Enum.join(payload.git_log.lines, "\n") %></pre>
              <% :empty -> %>
                <p class="empty-state">No git history.</p>
              <% :workspace_not_present -> %>
                <p class="empty-state">Workspace not present.</p>
              <% :unsafe_workspace -> %>
                <p class="empty-state">Workspace path is not contained in the configured workspace root.</p>
              <% :unconfigured -> %>
                <p class="empty-state">No workspace configured for this session.</p>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Recent log entries</h2>
                <p class="section-copy">Last matching lines from the application log for this session.</p>
              </div>
            </div>

            <%= case payload.log_tail.status do %>
              <% :ok -> %>
                <pre class="code-panel"><%= Enum.join(payload.log_tail.lines, "\n") %></pre>
              <% :empty -> %>
                <p class="empty-state">No log entries — log file not present.</p>
              <% :no_entries -> %>
                <p class="empty-state">No log entries.</p>
              <% :unconfigured -> %>
                <p class="empty-state">No log entries.</p>
              <% :error -> %>
                <p class="empty-state">No log entries.</p>
            <% end %>
          </section>
        </section>
    <% end %>
    """
  end

  defp assign_payload(socket) do
    snapshot = snapshot()
    filesystem = filesystem_context()
    result = SessionDetailPresenter.payload(socket.assigns.raw_identifier, snapshot, filesystem)
    assign(socket, :result, result)
  end

  defp filesystem_context do
    case SardineRun.Config.settings() do
      {:ok, settings} ->
        %{
          workspace_root: settings.workspace.root,
          log_file: SardineRun.LogFile.default_log_file()
        }

      _ ->
        %{}
    end
  end

  defp snapshot do
    case SardineRun.Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms()) do
      %{} = snap -> snap
      _other -> %{running: [], retrying: []}
    end
  end

  defp orchestrator, do: Endpoint.config(:orchestrator) || SardineRun.Orchestrator

  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp status_badge_class("running"), do: "status-badge status-badge-live"
  defp status_badge_class("retrying"), do: "status-badge status-badge-offline"
  defp status_badge_class(_), do: "status-badge"

  defp format_int(value) when is_integer(value), do: Integer.to_string(value)
  defp format_int(_value), do: "n/a"
end
