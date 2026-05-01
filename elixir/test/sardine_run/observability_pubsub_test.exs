defmodule SardineRun.ObservabilityPubSubTest do
  use SardineRun.TestSupport

  alias SardineRunWeb.ObservabilityPubSub

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(SardineRun.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(SardineRun.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(SardineRun.PubSub))
    assert :ok = Supervisor.terminate_child(SardineRun.Supervisor, pubsub_child_id)
    refute Process.whereis(SardineRun.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_update()
  end
end
