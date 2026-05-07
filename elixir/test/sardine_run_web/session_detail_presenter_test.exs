defmodule SardineRunWeb.SessionDetailPresenterTest do
  use ExUnit.Case, async: true

  alias SardineRunWeb.SessionDetailPresenter

  describe "validate_identifier/1" do
    test "accepts identifiers matching the SessionWriter allow-list" do
      for identifier <- ["UPS-123", "MT-188", "foo.bar", "a_b", "abc", "9999", "X-1.0_2"] do
        assert {:ok, ^identifier} = SessionDetailPresenter.validate_identifier(identifier)
      end
    end

    test "rejects empty, traversal, slash, and whitespace identifiers" do
      for identifier <- ["", "..", "../etc", "a/b", "a b", "a\nb", "foo/", "/abs", "../../boom"] do
        assert {:error, :invalid_identifier} =
                 SessionDetailPresenter.validate_identifier(identifier)
      end
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_identifier} = SessionDetailPresenter.validate_identifier(nil)
      assert {:error, :invalid_identifier} = SessionDetailPresenter.validate_identifier(123)
      assert {:error, :invalid_identifier} = SessionDetailPresenter.validate_identifier(:atom)
    end
  end

  describe "payload/3 — running issue" do
    setup do
      now = DateTime.utc_now()
      started_at = DateTime.add(now, -90, :second)

      running_entry = %{
        issue_id: "id-001",
        identifier: "UPS-123",
        state: "In Progress",
        worker_host: "worker-1",
        workspace_path: "/tmp/ws/UPS-123",
        session_id: "sess-abc",
        codex_app_server_pid: nil,
        codex_input_tokens: 100,
        codex_output_tokens: 250,
        codex_total_tokens: 350,
        turn_count: 4,
        started_at: started_at,
        last_codex_timestamp: now,
        last_codex_message: %{"type" => "agent_message", "message" => "hello"},
        last_codex_event: "agent_message",
        runtime_seconds: 90
      }

      snapshot = %{running: [running_entry], retrying: []}

      {:ok, snapshot: snapshot, started_at: started_at, now: now}
    end

    test "returns a running payload for a known identifier", %{snapshot: snapshot} do
      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-123", snapshot, %{})

      assert payload.identifier == "UPS-123"
      assert payload.status == "running"

      assert payload.header.issue_id == "id-001"
      assert payload.header.identifier == "UPS-123"
      assert payload.header.worker_host == "worker-1"
      assert payload.header.workspace_path == "/tmp/ws/UPS-123"

      assert payload.live_state.session_id == "sess-abc"
      assert payload.live_state.turn_count == 4
      assert payload.live_state.state == "In Progress"
      assert payload.live_state.last_event == "agent_message"
      assert payload.live_state.tokens == %{input_tokens: 100, output_tokens: 250, total_tokens: 350}
      assert is_binary(payload.live_state.started_at)
      assert is_binary(payload.live_state.last_event_at)
      assert is_binary(payload.live_state.last_message)
      assert payload.live_state.retry == nil
      assert payload.live_state.last_error == nil
    end
  end

  describe "payload/3 — retrying issue" do
    setup do
      retry_entry = %{
        issue_id: "id-002",
        identifier: "UPS-456",
        attempt: 2,
        due_in_ms: 30_000,
        error: "boom",
        worker_host: "worker-2",
        workspace_path: "/tmp/ws/UPS-456"
      }

      snapshot = %{running: [], retrying: [retry_entry]}

      {:ok, snapshot: snapshot}
    end

    test "returns a retrying payload for a known identifier", %{snapshot: snapshot} do
      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-456", snapshot, %{})

      assert payload.identifier == "UPS-456"
      assert payload.status == "retrying"

      assert payload.header.issue_id == "id-002"
      assert payload.header.worker_host == "worker-2"
      assert payload.header.workspace_path == "/tmp/ws/UPS-456"

      assert payload.live_state.retry == %{
               attempt: 2,
               due_at: payload.live_state.retry.due_at
             }

      assert is_binary(payload.live_state.retry.due_at)
      assert payload.live_state.last_error == "boom"
    end
  end

  describe "payload/3 — not found and invalid input" do
    test "returns :not_found when the identifier is in neither list" do
      snapshot = %{running: [], retrying: []}

      assert {:error, :not_found} =
               SessionDetailPresenter.payload("UPS-MISSING", snapshot, %{})
    end

    test "returns :invalid_identifier when the identifier fails the allow-list" do
      snapshot = %{running: [], retrying: []}

      assert {:error, :invalid_identifier} =
               SessionDetailPresenter.payload("../etc", snapshot, %{})

      assert {:error, :invalid_identifier} =
               SessionDetailPresenter.payload("a/b", snapshot, %{})
    end

    test "returns :not_found when the snapshot is malformed (no lists)" do
      assert {:error, :not_found} = SessionDetailPresenter.payload("UPS-1", %{}, %{})
    end
  end

  describe "payload/3 — running takes precedence over retrying" do
    test "if the identifier appears in both running and retrying, status is running" do
      now = DateTime.utc_now()
      started_at = DateTime.add(now, -10, :second)

      running_entry = %{
        issue_id: "id-001",
        identifier: "UPS-DUP",
        state: "In Progress",
        worker_host: nil,
        workspace_path: nil,
        session_id: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        turn_count: 0,
        started_at: started_at,
        last_codex_timestamp: nil,
        last_codex_message: nil,
        last_codex_event: nil,
        runtime_seconds: 10
      }

      retry_entry = %{
        issue_id: "id-001",
        identifier: "UPS-DUP",
        attempt: 1,
        due_in_ms: 1_000,
        error: nil,
        worker_host: nil,
        workspace_path: nil
      }

      snapshot = %{running: [running_entry], retrying: [retry_entry]}

      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-DUP", snapshot, %{})
      assert payload.status == "running"
    end
  end
end
