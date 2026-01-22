defmodule MiniMe.Chat.Message do
  @moduledoc """
  A chat message in a workspace conversation.

  Messages can optionally belong to an execution session, which groups them
  within a bounded agent context (e.g., a Claude Code session).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(user assistant system tool_call error session_start session_end)

  schema "messages" do
    field :type, :string
    field :content, :string
    field :tool_data, :map

    belongs_to :workspace, MiniMe.Workspaces.Workspace
    belongs_to :execution_session, MiniMe.Chat.ExecutionSession

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:workspace_id, :execution_session_id, :type, :content, :tool_data])
    |> validate_required([:workspace_id, :type])
    |> validate_inclusion(:type, @types)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:execution_session_id)
  end

  @doc """
  Build a message struct for display (matches the in-memory format used by SessionLive).
  """
  def to_display(%__MODULE__{} = message) do
    base = %{
      id: message.id,
      type: String.to_existing_atom(message.type),
      content: message.content,
      timestamp: message.inserted_at,
      execution_session_id: message.execution_session_id
    }

    case message.type do
      "tool_call" ->
        tool_data = message.tool_data || %{}

        Map.merge(base, %{
          tool_use_id: tool_data["tool_use_id"],
          name: tool_data["name"],
          input: tool_data["input"],
          output: tool_data["output"],
          is_error: tool_data["is_error"] || false,
          collapsed: true
        })

      _ ->
        base
    end
  end
end
