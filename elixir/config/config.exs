import Config

config :phoenix, :json_library, Jason

config :sardine_run, SardineRunWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SardineRunWeb.ErrorHTML, json: SardineRunWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SardineRun.PubSub,
  live_view: [signing_salt: "sardine-run-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
