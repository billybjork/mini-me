defmodule MiniMe.Tasks.Task do
  @moduledoc """
  Schema representing a task with a cloned GitHub repo in a Sprite VM.

  A task represents a user's work session - it connects a GitHub repository
  to a Sprite environment where Claude can work on the code.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    field :github_repo_url, :string
    field :github_repo_name, :string
    field :sprite_name, :string
    field :working_dir, :string, default: "/home/sprite/repo"
    field :status, :string, default: "pending"
    field :error_message, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new task.
  """
  def changeset(task, attrs) do
    task
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
  Changeset for updating task status.
  """
  def status_changeset(task, attrs) do
    task
    |> cast(attrs, [:status, :error_message])
    |> validate_inclusion(:status, ["pending", "creating", "cloning", "ready", "error"])
  end
end
