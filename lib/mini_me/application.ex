defmodule MiniMe.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MiniMeWeb.Telemetry,
      MiniMe.Repo,
      {DNSCluster, query: Application.get_env(:mini_me, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MiniMe.PubSub},
      # OAuth token manager - handles automatic refresh of Claude access tokens.
      # Must start after Repo (needs DB) but before anything that makes API calls.
      MiniMe.Auth.ClaudeTokenManager,
      # Registry for session process lookup
      {Registry, keys: :unique, name: MiniMe.Sessions.Registry},
      # Sprite allocator for managing sandbox allocation
      MiniMe.Sandbox.Allocator,
      # DynamicSupervisor for user sessions
      {DynamicSupervisor, strategy: :one_for_one, name: MiniMe.SessionSupervisor},
      # Start to serve requests, typically the last entry
      MiniMeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MiniMe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MiniMeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
