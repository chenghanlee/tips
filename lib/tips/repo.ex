defmodule Tips.Repo do
  use Ecto.Repo,
    otp_app: :tips,
    adapter: Ecto.Adapters.Postgres
end
