defmodule MiniMe.Sessions.Registry do
  @moduledoc """
  Registry for looking up user sessions by workspace ID.
  Uses Elixir's built-in Registry for process tracking.
  """

  @registry_name __MODULE__

  @doc """
  Returns the registry name for use in supervision tree.
  """
  def registry_name, do: @registry_name

  @doc """
  Register a session process for a workspace.
  """
  def register(workspace_id) do
    Registry.register(@registry_name, workspace_id, nil)
  end

  @doc """
  Look up a session process by workspace ID.
  Returns `{:ok, pid}` or `:error`.
  """
  def lookup(workspace_id) do
    case Registry.lookup(@registry_name, workspace_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Check if a session exists for a workspace.
  """
  def exists?(workspace_id) do
    case lookup(workspace_id) do
      {:ok, _pid} -> true
      :error -> false
    end
  end

  @doc """
  Get all registered sessions.
  Returns a list of `{workspace_id, pid}` tuples.
  """
  def all_sessions do
    Registry.select(@registry_name, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
