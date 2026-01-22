defmodule MiniMe.Chat do
  @moduledoc """
  Context for managing chat messages and execution sessions.
  """
  import Ecto.Query
  alias MiniMe.Repo
  alias MiniMe.Chat.{ExecutionSession, Message}

  # Execution Sessions

  @doc """
  Start a new execution session for a workspace.
  """
  def start_execution_session(workspace_id, session_type \\ "claude_code") do
    ExecutionSession.start_changeset(workspace_id, session_type)
    |> Repo.insert()
  end

  @doc """
  Complete an execution session with the given status.
  """
  def complete_execution_session(session_or_id, status \\ "completed")

  def complete_execution_session(session_id, status) when is_integer(session_id) do
    case Repo.get(ExecutionSession, session_id) do
      nil -> {:error, :not_found}
      session -> complete_execution_session(session, status)
    end
  end

  def complete_execution_session(%ExecutionSession{} = session, status) do
    session
    |> ExecutionSession.complete_changeset(status)
    |> Repo.update()
  end

  @doc """
  Get the current active execution session for a workspace, if any.
  """
  def get_active_session(workspace_id) do
    ExecutionSession
    |> where([s], s.workspace_id == ^workspace_id and s.status == "started")
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
  end

  # Messages

  @doc """
  Create a message in a workspace.
  """
  def create_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a message and return the display format.
  """
  def create_message!(attrs) do
    {:ok, message} = create_message(attrs)
    Message.to_display(message)
  end

  @doc """
  Update a message (e.g., to add tool output).
  """
  def update_message(message_id, attrs) when is_integer(message_id) do
    case Repo.get(Message, message_id) do
      nil -> {:error, :not_found}
      message -> update_message(message, attrs)
    end
  end

  def update_message(%Message{} = message, attrs) do
    message
    |> Message.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Append content to an existing message (for streaming assistant responses).
  """
  def append_to_message(message_id, additional_content) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        new_content = (message.content || "") <> additional_content
        update_message(message, %{content: new_content})
    end
  end

  @doc """
  Update tool_data for a tool_call message (e.g., to add output).
  """
  def update_tool_result(message_id, output, is_error \\ false) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        tool_data = Map.merge(message.tool_data || %{}, %{"output" => output, "is_error" => is_error})
        update_message(message, %{tool_data: tool_data})
    end
  end

  @doc """
  Get all messages for a workspace, ordered by insertion time.
  Optionally preloads execution_session.
  """
  def list_messages(workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    query =
      Message
      |> where([m], m.workspace_id == ^workspace_id)
      |> order_by([m], asc: m.inserted_at)
      |> limit(^limit)

    query =
      if Keyword.get(opts, :preload_session, false) do
        preload(query, [:execution_session])
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Get messages for display in SessionLive.
  Returns messages in the format expected by the LiveView.
  """
  def list_messages_for_display(workspace_id, opts \\ []) do
    workspace_id
    |> list_messages(opts)
    |> Enum.map(&Message.to_display/1)
  end

  @doc """
  Get message by ID.
  """
  def get_message(id), do: Repo.get(Message, id)

  @doc """
  Find a tool_call message by tool_use_id within a workspace.
  """
  def find_tool_message(workspace_id, tool_use_id) do
    Message
    |> where([m], m.workspace_id == ^workspace_id and m.type == "tool_call")
    |> where([m], fragment("?->>'tool_use_id' = ?", m.tool_data, ^tool_use_id))
    |> order_by([m], desc: m.inserted_at)
    |> limit(1)
    |> Repo.one()
  end
end
