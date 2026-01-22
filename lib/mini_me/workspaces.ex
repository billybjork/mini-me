defmodule MiniMe.Workspaces do
  @moduledoc """
  Context for managing workspaces.
  """

  import Ecto.Query
  alias MiniMe.Repo
  alias MiniMe.Workspaces.Workspace

  @doc """
  Get a workspace by ID.
  """
  def get_workspace(id) do
    Repo.get(Workspace, id)
  end

  @doc """
  Get a workspace by ID, raising if not found.
  """
  def get_workspace!(id) do
    Repo.get!(Workspace, id)
  end

  @doc """
  Get a workspace by GitHub repo URL.
  """
  def get_workspace_by_repo_url(url) do
    Repo.get_by(Workspace, github_repo_url: url)
  end

  @doc """
  Get a workspace by sprite name.
  """
  def get_workspace_by_sprite(sprite_name) do
    Repo.get_by(Workspace, sprite_name: sprite_name)
  end

  @doc """
  List all workspaces.
  """
  def list_workspaces do
    Workspace
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  @doc """
  Create a new workspace.
  """
  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a workspace or return existing one for the given repo URL.
  """
  def find_or_create_workspace(repo_url, repo_name) do
    case get_workspace_by_repo_url(repo_url) do
      nil ->
        sprite_name = generate_sprite_name(repo_name)

        create_workspace(%{
          github_repo_url: repo_url,
          github_repo_name: repo_name,
          sprite_name: sprite_name
        })

      workspace ->
        {:ok, workspace}
    end
  end

  @doc """
  Update workspace status.
  """
  def update_status(workspace, status, error_message \\ nil) do
    workspace
    |> Workspace.status_changeset(%{status: status, error_message: error_message})
    |> Repo.update()
  end

  @doc """
  Delete a workspace.
  """
  def delete_workspace(workspace) do
    Repo.delete(workspace)
  end

  # Private Functions

  defp generate_sprite_name(repo_name) do
    # Convert "owner/repo" to a valid sprite name
    # Remove special characters and add a unique suffix
    base =
      repo_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{base}-#{suffix}"
  end
end
