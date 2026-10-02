defmodule Tips.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    TipsWeb.LiveLogger.attach()

    children = [
      TwMerge.Cache,
      TipsWeb.Telemetry,
      Tips.Repo,
      {Oban, Application.fetch_env!(:tips, Oban)},
      {DNSCluster, query: Application.get_env(:tips, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tips.PubSub},
      {Tips.AdmissionLimiter, Application.fetch_env!(:tips, Tips.AdmissionLimiter)},
      # Start a worker by calling: Tips.Worker.start_link(arg)
      # {Tips.Worker, arg},
      # Start to serve requests, typically the last entry
      TipsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tips.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TipsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
