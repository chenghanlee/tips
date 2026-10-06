import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tips, Tips.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5433")),
  database: "tips_test#{System.get_env("TIPS_DB_SUFFIX")}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

port = String.to_integer(System.get_env("TIPS_TEST_PORT", "4002"))

config :tips, :sql_sandbox, true

config :tips, TipsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  secret_key_base: "gxew8SnxosBITKPd0wkqsojsMlaW7Ee9HTrithPNvzD86TbQJQ2r4eAh2NqNsY2i",
  server: true

config :wallaby,
  otp_app: :tips,
  base_url: "http://localhost:#{port}",
  driver: Wallaby.Chrome,
  chromedriver: [
    headless: true,
    # Wallaby defaults without --no-sandbox. Keep --user-agent for sandbox metadata.
    capabilities: %{
      javascriptEnabled: false,
      loadImages: false,
      version: "",
      rotatable: false,
      takesScreenshot: true,
      cssSelectorsEnabled: true,
      nativeEvents: false,
      platform: "ANY",
      unhandledPromptBehavior: "accept",
      loggingPrefs: %{browser: "DEBUG"},
      chromeOptions: %{
        args: [
          "window-size=1280,800",
          "--disable-gpu",
          "--headless",
          "--fullscreen",
          "--user-agent=Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"
        ]
      }
    }
  ],
  screenshot_on_failure: true,
  screenshot_dir: "screenshots"

if binary = System.get_env("TIPS_CHROME_BINARY") do
  config :wallaby, chromedriver: [binary: binary]
end

if path = System.get_env("TIPS_CHROMEDRIVER") do
  config :wallaby, chromedriver: [path: path]
end

# In test we don't send emails. Tips.MailerTestAdapter delegates to Swoosh.Adapters.Test
# unless a test scripts its own delivery outcome.
config :tips, Tips.Mailer, adapter: Tips.MailerTestAdapter

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :tips, Oban, testing: :manual

# Embedding requests reach Req.Test stubs, never the network, even with TIPS_REAL_PROVIDERS=1.
# An unstubbed request raises.
config :tips, Tips.Content.Search.EmbeddingProvider,
  api_key: "synthetic-test-key",
  plug: {Req.Test, Tips.Content.Search.EmbeddingProvider}

# R2 requests reach Req.Test stubs with synthetic settings. Only `:real_provider` tests
# override both to reach the development bucket.
config :tips, Tips.Content.Media.R2,
  plug: {Req.Test, Tips.Content.Media.R2},
  settings: %{
    endpoint: "https://r2.test",
    bucket: "tips-test",
    access_key_id: "synthetic-access-key",
    secret_access_key: "synthetic-secret-key"
  }

# Saturation tests wait for capacity; keep each wait short.
config :tips, Tips.Content.Search.ProviderCapacity, size: 8, queue_wait: 200
