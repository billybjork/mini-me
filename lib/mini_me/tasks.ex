defmodule MiniMe.Tasks do
  @moduledoc """
  Context for managing tasks (conversations).

  Tasks are conversations that may optionally be associated with a repository.
  They are decoupled from infrastructure - sprites are allocated dynamically.
  """

  import Ecto.Query
  alias MiniMe.Repo
  alias MiniMe.Tasks.Task

  @doc """
  Get a task by ID.
  """
  def get_task(id), do: Repo.get(Task, id)

  @doc """
  Get a task by ID, raising if not found.
  """
  def get_task!(id), do: Repo.get!(Task, id)

  @doc """
  Get a task by ID with repo preloaded.
  """
  def get_task_with_repo!(id) do
    Task
    |> preload(:repo)
    |> Repo.get!(id)
  end

  @doc """
  List all tasks, ordered by most recently updated.
  Optionally preload repo.
  """
  def list_tasks(opts \\ []) do
    query =
      Task
      |> order_by(desc: :updated_at)

    query =
      if Keyword.get(opts, :preload_repo, false) do
        preload(query, :repo)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  List tasks by status.
  """
  def list_tasks_by_status(status) when status in ~w(active awaiting_input idle) do
    Task
    |> where([t], t.status == ^status)
    |> order_by(desc: :updated_at)
    |> preload(:repo)
    |> Repo.all()
  end

  @doc """
  Create a new task.
  """
  def create_task(attrs \\ %{}) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a task with an associated repo.
  """
  def create_task_for_repo(repo) do
    create_task(%{repo_id: repo.id})
  end

  @doc """
  Update a task.
  """
  def update_task(task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Update task status.
  """
  def update_status(task, status) when status in ~w(active awaiting_input idle) do
    task
    |> Task.status_changeset(status)
    |> Repo.update()
  end

  @doc """
  Mark task as active (Claude is working).
  """
  def mark_active(task), do: update_status(task, "active")

  @doc """
  Mark task as awaiting input (Claude finished, user's turn).
  """
  def mark_awaiting_input(task), do: update_status(task, "awaiting_input")

  @doc """
  Mark task as idle (no activity).
  """
  def mark_idle(task), do: update_status(task, "idle")

  @doc """
  Delete a task. Returns :ok even if already deleted (idempotent).
  Stops any running session and releases sprite allocation.
  """
  def delete_task(task) do
    # Stop the UserSession if running (this will call Allocator.release via terminate/2)
    case MiniMe.Sessions.Registry.lookup(task.id) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      :error -> MiniMe.Sandbox.Allocator.release(task)
    end

    case Repo.delete(task, allow_stale: true) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @doc """
  Touch the task's updated_at timestamp.
  """
  def touch(task) do
    task
    |> Ecto.Changeset.change()
    |> Repo.update(force: true)
  end
end
