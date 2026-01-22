defmodule MiniMe.Chat.ExecutionSession do
  @moduledoc """
  Tracks the lifecycle of an agent execution session (e.g., Claude Code).

  An execution session represents a bounded context where an agent has memory
  and continuity. When the session ends, subsequent messages start fresh.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(started completed failed interrupted)

  schema "execution_sessions" do
    field :session_type, :string, default: "claude_code"
    field :status, :string, default: "started"
    field :sprite_name, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :task, MiniMe.Tasks.Task
    has_many :messages, MiniMe.Chat.Message

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :task_id,
      :session_type,
      :status,
      :sprite_name,
      :started_at,
      :ended_at,
      :metadata
    ])
    |> validate_required([:task_id, :session_type, :status, :started_at])
    |> validate_inclusion(:status, @statuses)
    # Constraint was originally named for workspace_id before rename migration
    |> foreign_key_constraint(:task_id, name: :execution_sessions_workspace_id_fkey)
  end

  def start_changeset(task_id, sprite_name, session_type \\ "claude_code") do
    changeset(%__MODULE__{}, %{
      task_id: task_id,
      sprite_name: sprite_name,
      session_type: session_type,
      status: "started",
      started_at: DateTime.utc_now()
    })
  end

  def complete_changeset(session, status \\ "completed")
      when status in ["completed", "failed", "interrupted"] do
    changeset(session, %{
      status: status,
      ended_at: DateTime.utc_now()
    })
  end
end
