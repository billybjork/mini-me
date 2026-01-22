defmodule MiniMe.Tasks.Task do
  @moduledoc """
  Schema representing a task (conversation).

  A task is a conversation that may optionally be associated with a GitHub
  repository. Tasks are decoupled from infrastructure - sprites are allocated
  dynamically when execution is needed.

  Status is derived from execution state:
  - :active - Claude is currently working
  - :awaiting_input - Claude finished, waiting for user
  - :idle - No recent activity
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active awaiting_input idle)

  schema "tasks" do
    field :title, :string
    field :status, :string, default: "idle"

    belongs_to :repo, MiniMe.Repos.Repo
    has_many :messages, MiniMe.Chat.Message
    has_many :execution_sessions, MiniMe.Chat.ExecutionSession

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new task.
  """
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :status, :repo_id])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:repo_id)
  end

  @doc """
  Changeset for updating task status.
  """
  def status_changeset(task, status) when status in @statuses do
    change(task, status: status)
  end
end
