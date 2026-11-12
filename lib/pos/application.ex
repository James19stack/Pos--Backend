defmodule Pos.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PosWeb.Telemetry,
      Pos.Repo,
      {Oban, Application.fetch_env!(:pos, Oban)},
      {DNSCluster, query: Application.get_env(:pos, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pos.PubSub},
      # Start a worker by calling: Pos.Worker.start_link(arg)
      # {Pos.Worker, arg},
      # Start to serve requests, typically the last entry
      PosWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pos.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PosWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
