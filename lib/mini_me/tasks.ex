defmodule MiniMe.Tasks do
  @moduledoc """
  Context for managing tasks.

  A task represents a user's work session with a GitHub repository running in a Sprite VM.
  """

  import Ecto.Query
  alias MiniMe.Repo
  alias MiniMe.Tasks.Task

  @doc """
  Get a task by ID.
  """
  def get_task(id) do
    Repo.get(Task, id)
  end

  @doc """
  Get a task by ID, raising if not found.
  """
  def get_task!(id) do
    Repo.get!(Task, id)
  end

  @doc """
  Get a task by GitHub repo URL.
  """
  def get_task_by_repo_url(url) do
    Repo.get_by(Task, github_repo_url: url)
  end

  @doc """
  Get a task by sprite name.
  """
  def get_task_by_sprite(sprite_name) do
    Repo.get_by(Task, sprite_name: sprite_name)
  end

  @doc """
  List all tasks.
  """
  def list_tasks do
    Task
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  @doc """
  Create a new task.
  """
  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a task or return existing one for the given repo URL.
  """
  def find_or_create_task(repo_url, repo_name) do
    case get_task_by_repo_url(repo_url) do
      nil ->
        sprite_name = generate_sprite_name(repo_name)

        create_task(%{
          github_repo_url: repo_url,
          github_repo_name: repo_name,
          sprite_name: sprite_name
        })

      task ->
        {:ok, task}
    end
  end

  @doc """
  Update task status.
  """
  def update_status(task, status, error_message \\ nil) do
    task
    |> Task.status_changeset(%{status: status, error_message: error_message})
    |> Repo.update()
  end

  @doc """
  Delete a task. Returns :ok even if already deleted (idempotent).
  """
  def delete_task(task) do
    case Repo.delete(task, allow_stale: true) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
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
