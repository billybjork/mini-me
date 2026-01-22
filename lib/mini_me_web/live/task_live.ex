defmodule MiniMeWeb.TaskLive do
  @moduledoc """
  LiveView for a single task - chat interface for agent conversations.
  """
  use MiniMeWeb, :live_view

  alias MiniMe.Tasks
  alias MiniMe.Sessions.{Registry, UserSession}
  alias MiniMe.Chat

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    task = Tasks.get_task_with_repo!(id)

    # Load persisted messages
    messages = Chat.list_messages_for_display(task.id)

    # Build a map of messages that may need updates (tool_call messages)
    messages_map =
      messages
      |> Enum.filter(&(&1.type == :tool_call))
      |> Map.new(&{&1.id, &1})

    socket =
      socket
      |> assign(:task, task)
      |> stream(:messages, messages)
      |> assign(:messages_map, messages_map)
      |> assign(:status, :initializing)
      |> assign(:current_tool, nil)
      |> assign(:input, "")
      |> assign(:session_pid, nil)
      |> assign(:execution_session_id, nil)
      |> assign(:streaming_message_id, nil)
      |> assign(:streaming_message, nil)

    if connected?(socket) do
      # Subscribe to session events
      Phoenix.PubSub.subscribe(MiniMe.PubSub, UserSession.pubsub_topic(task.id))

      # Start or find existing session
      send(self(), :ensure_session)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:ensure_session, socket) do
    task = socket.assigns.task

    case Registry.lookup(task.id) do
      {:ok, pid} ->
        # Session exists, monitor it and get its status
        Process.monitor(pid)
        status = UserSession.status(pid)
        exec_session_id = UserSession.execution_session_id(pid)

        {:noreply,
         assign(socket,
           session_pid: pid,
           status: status.status,
           execution_session_id: exec_session_id
         )}

      :error ->
        # Start new session
        case DynamicSupervisor.start_child(
               MiniMe.SessionSupervisor,
               {UserSession, task}
             ) do
          {:ok, pid} ->
            Process.monitor(pid)
            {:noreply, assign(socket, session_pid: pid)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:status, :error)
             |> add_message(:system, "Failed to start session: #{inspect(reason)}")}
        end
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, socket) do
    if socket.assigns.session_pid == pid do
      require Logger
      Logger.warning("Session process died: #{inspect(reason)}")

      socket =
        socket
        |> assign(:session_pid, nil)
        |> assign(:status, :disconnected)
        |> add_message(:system, "Session disconnected. Refresh to reconnect.")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Handle PubSub messages from UserSession
  def handle_info({:session_status, status}, socket) do
    socket = assign(socket, :status, status)

    socket =
      case status do
        :connecting ->
          add_message(socket, :system, "Connecting to sandbox...")

        :starting_agent ->
          add_message(socket, :system, "Starting agent...")

        :ready ->
          socket

        :processing ->
          socket

        :disconnected ->
          add_message(socket, :system, "Disconnected. Attempting to reconnect...")

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:agent_text, text}, socket) do
    # Append text to the last assistant message or create new one
    socket = append_to_assistant_message(socket, text)
    {:noreply, push_event(socket, "scroll_bottom", %{})}
  end

  def handle_info({:tool_use, tool}, socket) do
    task_id = socket.assigns.task.id
    execution_session_id = socket.assigns.execution_session_id
    formatted_input = format_tool_input(tool.name, tool.input)

    # Persist to database
    {:ok, db_message} =
      Chat.create_message(%{
        task_id: task_id,
        execution_session_id: execution_session_id,
        type: "tool_call",
        tool_data: %{
          "tool_use_id" => tool.id,
          "name" => tool.name,
          "input" => formatted_input,
          "output" => nil,
          "is_error" => false
        }
      })

    message = Chat.Message.to_display(db_message)

    socket =
      socket
      |> assign(:current_tool, tool.name)
      |> stream_insert(:messages, message)
      |> update(:messages_map, &Map.put(&1, message.id, message))

    {:noreply, push_event(socket, "scroll_bottom", %{})}
  end

  def handle_info({:tool_result, result}, socket) do
    # Find and update the tool message in our map
    messages_map = socket.assigns.messages_map

    socket =
      Enum.find_value(messages_map, socket, fn {_id, msg} ->
        if msg.tool_use_id == result.tool_use_id do
          output = extract_tool_output(result)
          updated_msg = %{msg | output: output, is_error: result.is_error}

          socket
          |> stream_insert(:messages, updated_msg)
          |> update(:messages_map, &Map.put(&1, msg.id, updated_msg))
        end
      end)

    # Persist tool result to database
    task_id = socket.assigns.task.id
    output = extract_tool_output(result)

    if tool_msg = Chat.find_tool_message(task_id, result.tool_use_id) do
      Chat.update_tool_result(tool_msg.id, output, result.is_error)
    end

    {:noreply, push_event(socket, "scroll_bottom", %{})}
  end

  def handle_info({:agent_done}, socket) do
    {:noreply,
     assign(socket, current_tool: nil, streaming_message_id: nil, streaming_message: nil)}
  end

  def handle_info({:agent_error, reason}, socket) do
    socket =
      socket
      |> assign(:status, :error)
      |> add_message(:error, reason)

    {:noreply, socket}
  end

  def handle_info({:execution_session_started, session_id}, socket) do
    socket =
      socket
      |> assign(:execution_session_id, session_id)
      |> add_message(:session_start, nil)

    {:noreply, socket}
  end

  def handle_info({:execution_session_ended, _session_id, status}, socket) do
    socket =
      socket
      |> assign(:execution_session_id, nil)
      |> add_message(:session_end, status)

    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    require Logger
    Logger.debug("TaskLive received: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) when message != "" do
    require Logger

    Logger.debug(
      "TaskLive.send: session_pid=#{inspect(socket.assigns.session_pid)}, status=#{socket.assigns.status}"
    )

    socket =
      socket
      |> add_message(:user, message)
      |> assign(:input, "")

    if socket.assigns.session_pid do
      UserSession.send_message(socket.assigns.session_pid, message)
    else
      Logger.warning("TaskLive.send: No session_pid, message dropped!")
    end

    {:noreply, push_event(socket, "scroll_bottom", %{})}
  end

  def handle_event("send", _, socket), do: {:noreply, socket}

  def handle_event("interrupt", _, socket) do
    if socket.assigns.session_pid do
      UserSession.interrupt(socket.assigns.session_pid)
    end

    {:noreply, add_message(socket, :system, "Interrupting...")}
  end

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("toggle_tool", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Map.get(socket.assigns.messages_map, id) do
      nil ->
        {:noreply, socket}

      msg ->
        updated_msg = %{msg | collapsed: !msg.collapsed}

        socket =
          socket
          |> stream_insert(:messages, updated_msg)
          |> update(:messages_map, &Map.put(&1, id, updated_msg))

        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.full_screen flash={@flash}>
      <div
        class="flex flex-col h-screen bg-gray-900 text-white"
        id="session-container"
        phx-hook="ScrollBottom"
      >
        <!-- Header -->
        <header class="flex-none p-4 border-b border-gray-700">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-lg font-semibold">{task_display_name(@task)}</h1>
              <div class="text-sm text-gray-400">
                <span class={status_color(@status)}>{status_text(@status)}</span>
                <span :if={@current_tool} class="ml-2 text-yellow-400">
                  Running: {@current_tool}
                </span>
              </div>
            </div>
            <div class="flex gap-2">
              <button
                :if={@status == :processing}
                phx-click="interrupt"
                class="px-3 py-1 bg-red-600 hover:bg-red-700 rounded text-sm"
              >
                Interrupt
              </button>
              <.link navigate={~p"/"} class="px-3 py-1 bg-gray-700 hover:bg-gray-600 rounded text-sm">
                Back
              </.link>
            </div>
          </div>
        </header>
        
    <!-- Messages -->
        <div class="flex-1 overflow-y-auto p-4 space-y-4" id="messages" phx-update="stream">
          <div :for={{dom_id, msg} <- @streams.messages} id={dom_id}>
            <%= case msg.type do %>
              <% :session_start -> %>
                <div class="flex items-center gap-3 py-2">
                  <div class="flex-1 h-px bg-green-700"></div>
                  <span class="text-xs text-green-500 font-medium px-2">
                    Session Started
                  </span>
                  <div class="flex-1 h-px bg-green-700"></div>
                </div>
              <% :session_end -> %>
                <div class="flex items-center gap-3 py-2">
                  <div class="flex-1 h-px bg-gray-600"></div>
                  <span class={"text-xs font-medium px-2 #{session_end_color(msg.content)}"}>
                    Session {session_end_text(msg.content)}
                  </span>
                  <div class="flex-1 h-px bg-gray-600"></div>
                </div>
              <% :tool_call -> %>
                <div class="border border-gray-700 rounded-lg overflow-hidden">
                  <button
                    phx-click="toggle_tool"
                    phx-value-id={msg.id}
                    class="w-full flex items-center gap-2 px-3 py-2 bg-gray-800 hover:bg-gray-750 text-left text-sm"
                  >
                    <span
                      class="text-gray-500 transition-transform duration-200"
                      style={if msg.collapsed, do: "", else: "transform: rotate(90deg)"}
                    >
                      ▶
                    </span>
                    <span class="text-yellow-400 font-medium">{msg.name}</span>
                    <span class="text-gray-400 truncate flex-1 font-mono text-xs">{msg.input}</span>
                    <span :if={msg.is_error} class="text-red-400 text-xs">error</span>
                  </button>
                  <div class={[
                    "px-3 py-2 bg-gray-900 border-t border-gray-700",
                    msg.collapsed && "hidden"
                  ]}>
                    <div class="text-xs text-gray-500 mb-1">Input</div>
                    <div class="whitespace-pre-wrap font-mono text-xs text-gray-300 mb-2">
                      {msg.input}
                    </div>
                    <div :if={msg.output}>
                      <div class="text-xs text-gray-500 mb-1 mt-2">Output</div>
                      <div class={[
                        "whitespace-pre-wrap font-mono text-xs max-h-64 overflow-y-auto",
                        if(msg.is_error, do: "text-red-400", else: "text-gray-300")
                      ]}>
                        {msg.output}
                      </div>
                    </div>
                    <div :if={!msg.output} class="text-xs text-gray-500 italic">Running...</div>
                  </div>
                </div>
              <% :assistant -> %>
                <div class={message_class(:assistant)}>
                  <div class="text-xs text-gray-500 mb-1">assistant</div>
                  <div class="markdown-content text-sm">{raw(render_markdown(msg.content))}</div>
                </div>
              <% _ -> %>
                <div class={message_class(msg.type)}>
                  <div class="text-xs text-gray-500 mb-1">{msg.type}</div>
                  <div class="whitespace-pre-wrap font-mono text-sm">{msg.content}</div>
                </div>
            <% end %>
          </div>
        </div>
        
    <!-- Input -->
        <div class="flex-none p-4 border-t border-gray-700">
          <form phx-submit="send" class="flex gap-2">
            <input
              type="text"
              name="message"
              value={@input}
              phx-change="update_input"
              placeholder={if @status == :ready, do: "Type a message...", else: "Waiting..."}
              disabled={@status not in [:ready, :processing]}
              class="flex-1 px-4 py-2 bg-gray-800 border border-gray-600 rounded-lg focus:outline-none focus:border-blue-500 disabled:opacity-50"
              autocomplete="off"
            />
            <button
              type="submit"
              disabled={@status not in [:ready, :processing] or @input == ""}
              class="px-6 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-600 disabled:cursor-not-allowed rounded-lg font-semibold transition-colors"
            >
              Send
            </button>
          </form>
        </div>
      </div>
    </Layouts.full_screen>
    """
  end

  # Helper functions

  defp extract_tool_output(%{stderr: stderr}) when stderr != "", do: stderr
  defp extract_tool_output(%{stdout: stdout}) when stdout != "", do: stdout
  defp extract_tool_output(_result), do: "(no output)"

  defp add_message(socket, type, content) do
    task_id = socket.assigns.task.id
    execution_session_id = socket.assigns.execution_session_id

    # Persist to database
    {:ok, db_message} =
      Chat.create_message(%{
        task_id: task_id,
        execution_session_id: execution_session_id,
        type: to_string(type),
        content: content
      })

    message = Chat.Message.to_display(db_message)
    stream_insert(socket, :messages, message)
  end

  defp append_to_assistant_message(socket, text) do
    streaming_id = socket.assigns.streaming_message_id
    streaming_msg = socket.assigns.streaming_message

    if streaming_id && streaming_msg && streaming_msg.type == :assistant do
      # Append to existing streaming message
      updated_msg = %{streaming_msg | content: (streaming_msg.content || "") <> text}

      # Persist the appended content
      Chat.append_to_message(streaming_id, text)

      socket
      |> assign(:streaming_message, updated_msg)
      |> stream_insert(:messages, updated_msg)
    else
      # Create a new assistant message
      task_id = socket.assigns.task.id
      execution_session_id = socket.assigns.execution_session_id

      {:ok, db_message} =
        Chat.create_message(%{
          task_id: task_id,
          execution_session_id: execution_session_id,
          type: "assistant",
          content: text
        })

      message = Chat.Message.to_display(db_message)

      socket
      |> assign(:streaming_message_id, db_message.id)
      |> assign(:streaming_message, message)
      |> stream_insert(:messages, message)
    end
  end

  defp message_class(:user), do: "p-3 bg-blue-900 rounded-lg ml-8"
  defp message_class(:assistant), do: "p-3 bg-gray-800 rounded-lg mr-8"
  defp message_class(:system), do: "p-2 text-gray-400 text-center text-sm"
  defp message_class(:tool), do: "p-2 text-yellow-400 text-sm"
  defp message_class(:error), do: "p-3 bg-red-900 rounded-lg"

  defp status_color(:ready), do: "text-green-400"
  defp status_color(:processing), do: "text-yellow-400"
  defp status_color(:connecting), do: "text-blue-400"
  defp status_color(:starting_agent), do: "text-blue-400"
  defp status_color(:error), do: "text-red-400"
  defp status_color(:disconnected), do: "text-orange-400"
  defp status_color(:idle), do: "text-gray-400"
  defp status_color(_), do: "text-gray-400"

  defp status_text(:ready), do: "Ready"
  defp status_text(:processing), do: "Processing..."
  defp status_text(:connecting), do: "Connecting..."
  defp status_text(:starting_agent), do: "Starting..."
  defp status_text(:error), do: "Error"
  defp status_text(:disconnected), do: "Disconnected"
  defp status_text(:initializing), do: "Initializing..."
  defp status_text(:idle), do: "Idle"
  defp status_text(status), do: to_string(status)

  defp session_end_color("completed"), do: "text-green-500"
  defp session_end_color("failed"), do: "text-red-500"
  defp session_end_color("interrupted"), do: "text-orange-500"
  defp session_end_color(_), do: "text-gray-500"

  defp session_end_text("completed"), do: "Completed"
  defp session_end_text("failed"), do: "Failed"
  defp session_end_text("interrupted"), do: "Interrupted"
  defp session_end_text(_), do: "Ended"

  defp format_tool_input("Bash", %{"command" => cmd}), do: cmd
  defp format_tool_input("Read", %{"file_path" => path}), do: path
  defp format_tool_input("Write", %{"file_path" => path}), do: path
  defp format_tool_input("Edit", %{"file_path" => path}), do: path
  defp format_tool_input("Glob", %{"pattern" => pattern}), do: pattern
  defp format_tool_input("Grep", %{"pattern" => pattern}), do: pattern
  defp format_tool_input("WebFetch", %{"url" => url}), do: url
  defp format_tool_input("WebSearch", %{"query" => query}), do: query
  defp format_tool_input("Task", %{"prompt" => prompt}), do: String.slice(prompt, 0, 100)

  defp format_tool_input(_name, input) when is_map(input) do
    input
    |> Map.take(["command", "file_path", "pattern", "query", "url", "prompt"])
    |> Map.values()
    |> List.first()
    |> case do
      nil -> inspect(input)
      val -> val
    end
  end

  defp format_tool_input(_name, input), do: inspect(input)

  defp render_markdown(content) when is_binary(content) do
    content
    |> Earmark.as_html!(code_class_prefix: "language-")
  end

  defp render_markdown(_), do: ""

  defp task_display_name(%{title: title}) when is_binary(title) and title != "", do: title
  defp task_display_name(%{repo: %{github_name: name}}) when is_binary(name), do: name
  defp task_display_name(%{id: id}), do: "Task ##{id}"
end
