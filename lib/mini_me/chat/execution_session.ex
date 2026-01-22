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
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :workspace, MiniMe.Workspaces.Workspace
    has_many :messages, MiniMe.Chat.Message

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:workspace_id, :session_type, :status, :started_at, :ended_at, :metadata])
    |> validate_required([:workspace_id, :session_type, :status, :started_at])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:workspace_id)
  end

  def start_changeset(workspace_id, session_type \\ "claude_code") do
    changeset(%__MODULE__{}, %{
      workspace_id: workspace_id,
      session_type: session_type,
      status: "started",
      started_at: DateTime.utc_now()
    })
  end

  def complete_changeset(session, status \\ "completed") when status in ["completed", "failed", "interrupted"] do
    changeset(session, %{
      status: status,
      ended_at: DateTime.utc_now()
    })
  end
end
