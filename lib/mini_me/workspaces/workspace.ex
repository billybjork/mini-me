defmodule MiniMe.Workspaces.Workspace do
  @moduledoc """
  Schema representing a workspace with a cloned GitHub repo in a Sprite VM.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "workspaces" do
    field :github_repo_url, :string
    field :github_repo_name, :string
    field :sprite_name, :string
    field :working_dir, :string, default: "/home/sprite/repo"
    field :status, :string, default: "pending"
    field :error_message, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new workspace.
  """
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [
      :github_repo_url,
      :github_repo_name,
      :sprite_name,
      :working_dir,
      :status,
      :error_message
    ])
    |> validate_required([:github_repo_url, :github_repo_name, :sprite_name])
    |> unique_constraint(:sprite_name)
    |> unique_constraint(:github_repo_url)
  end

  @doc """
  Changeset for updating workspace status.
  """
  def status_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:status, :error_message])
    |> validate_inclusion(:status, ["pending", "creating", "cloning", "ready", "error"])
  end
end
