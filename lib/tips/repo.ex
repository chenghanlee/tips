defmodule Tips.Repo do
  use Ecto.Repo,
    otp_app: :tips,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Runs maintenance SQL without the request deadline, unless a timeout is supplied.

  The timeout applies only to this call; it changes no connection settings.
  """
  def maintenance_query!(sql, params \\ [], opts \\ []) do
    query!(sql, params, Keyword.put_new(opts, :timeout, :infinity))
  end
end
