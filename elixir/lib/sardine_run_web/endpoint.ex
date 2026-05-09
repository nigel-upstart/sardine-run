defmodule SardineRunWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Sardine Run's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :sardine_run

  @session_options [
    store: :cookie,
    key: "_sardine_run_key",
    signing_salt: "sardine-run-session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SardineRunWeb.Router)
end
