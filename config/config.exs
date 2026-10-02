# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tips, :scopes,
  user: [
    default: true,
    module: Tips.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Tips.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :tips,
  ecto_repos: [Tips.Repo],
  generators: [timestamp_type: :utc_datetime]

config :tips, Tips.Repo, timeout: 2_000

config :tips, Oban,
  repo: Tips.Repo,
  queues: [media: 1, embeddings: 1, maintenance: 1],
  cron: [crontab: [{"* * * * *", Tips.Workers.ExpireRegistrations}]]

# Admission limits (Tips.AdmissionLimiter): {limit, window_ms} per bucket.
# MVP defaults chosen to allow ordinary use, not measured capacity. Windows are
# fixed from first admission, so up to twice a budget can pass around a window
# boundary. Buckets live in memory and reset on restart or deploy.
config :tips, Tips.AdmissionLimiter,
  # Sign-in, verification resend and email-change mail per normalized address:
  # a few retries for a slow inbox, while bounding mail sent to one address.
  auth_destination: {5, 15 * 60_000},
  # The same requests per client IP: room for a shared network, while bounding
  # one client that cycles through addresses.
  auth_ip: {30, 15 * 60_000},
  # Writes per account (publish, edit, vote, report): one a second on average,
  # enough for interactive voting and editing.
  write: {60, 60_000},
  # Uploads per account: a few attachments per contribution, while bounding
  # provider work.
  upload: {20, 10 * 60_000},
  # Rows per capacity class; the sum (10,000) is the table's hard bound. Classes
  # never lend rows, so anonymous auth traffic cannot deny signed-in writes or
  # uploads. A full class denies new identities rather than evicting live
  # buckets. Auth gets the most rows because each new identity may need two.
  capacity: [auth: 6_000, write: 2_000, upload: 2_000],
  # Sweep for expired rows in classes whose earliest expiry is due; one scan of
  # the capped table per due class.
  cleanup_interval_ms: 60_000

# Configure the endpoint
config :tips, TipsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TipsWeb.ErrorHTML, json: TipsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tips.PubSub,
  live_view: [signing_salt: "Y7A8yTcX"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tips, Tips.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tips: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  tips: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Keep credentials out of logged request parameters: any key containing these.
config :phoenix, :filter_parameters, ["password", "token"]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
