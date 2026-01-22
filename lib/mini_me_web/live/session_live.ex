defmodule MiniMeWeb.SessionLive do
  @moduledoc """
  Chat interface LiveView for interacting with Claude Code.
  """
  use MiniMeWeb, :live_view

  alias MiniMe.Workspaces
  alias MiniMe.Sessions.{Registry, UserSession}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = Workspaces.get_workspace!(id)

    socket =
      socket
      |> assign(:workspace, workspace)
      |> assign(:messages, [])
      |> assign(:status, :initializing)
      |> assign(:current_tool, nil)
      |> assign(:input, "")
      |> assign(:session_pid, nil)

    if connected?(socket) do
      # Subscribe to session events
      Phoenix.PubSub.subscribe(MiniMe.PubSub, UserSession.pubsub_topic(workspace.id))

      # Start or find existing session
      send(self(), :ensure_session)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:ensure_session, socket) do
    workspace = socket.assigns.workspace

    case Registry.lookup(workspace.id) do
      {:ok, pid} ->
        # Session exists, monitor it and get its status
        Process.monitor(pid)
        status = UserSession.status(pid)
        {:noreply, assign(socket, session_pid: pid, status: status.status)}

      :error ->
        # Start new session
        case DynamicSupervisor.start_child(
               MiniMe.SessionSupervisor,
               {UserSession, workspace}
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

        :cloning ->
          add_message(socket, :system, "Cloning repository...")

        :starting_claude ->
          add_message(socket, :system, "Starting Claude Code...")

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
    message = %{
      id: System.unique_integer([:positive]),
      type: :tool_call,
      tool_use_id: tool.id,
      name: tool.name,
      input: format_tool_input(tool.name, tool.input),
      output: nil,
      is_error: false,
      collapsed: true,
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> assign(:current_tool, tool.name)
      |> update(:messages, fn messages -> messages ++ [message] end)

    {:noreply, push_event(socket, "scroll_bottom", %{})}
  end

  def handle_info({:tool_result, result}, socket) do
    socket = update(socket, :messages, &apply_tool_result(&1, result))
    {:noreply, push_event(socket, "scroll_bottom", %{})}
  end

  def handle_info({:agent_done}, socket) do
    {:noreply, assign(socket, :current_tool, nil)}
  end

  def handle_info({:agent_error, reason}, socket) do
    socket =
      socket
      |> assign(:status, :error)
      |> add_message(:error, reason)

    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    require Logger
    Logger.debug("SessionLive received: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) when message != "" do
    require Logger
    Logger.debug("SessionLive.send: session_pid=#{inspect(socket.assigns.session_pid)}, status=#{socket.assigns.status}")

    socket =
      socket
      |> add_message(:user, message)
      |> assign(:input, "")

    if socket.assigns.session_pid do
      UserSession.send_message(socket.assigns.session_pid, message)
    else
      Logger.warning("SessionLive.send: No session_pid, message dropped!")
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
    socket = update(socket, :messages, &toggle_tool_message(&1, id))
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="flex flex-col h-screen bg-gray-900 text-white"
      id="session-container"
      phx-hook="ScrollBottom"
    >
      <!-- Header -->
      <header class="flex-none p-4 border-b border-gray-700">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-lg font-semibold">{@workspace.github_repo_name}</h1>
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
      <div class="flex-1 overflow-y-auto p-4 space-y-4" id="messages">
        <%= for msg <- @messages do %>
          <%= if msg.type == :tool_call do %>
            <div class="border border-gray-700 rounded-lg overflow-hidden">
              <button
                phx-click="toggle_tool"
                phx-value-id={msg.id}
                class="w-full flex items-center gap-2 px-3 py-2 bg-gray-800 hover:bg-gray-750 text-left text-sm"
              >
                <span class="text-gray-500 transition-transform duration-200" style={if msg.collapsed, do: "", else: "transform: rotate(90deg)"}>
                  ▶
                </span>
                <span class="text-yellow-400 font-medium">{msg.name}</span>
                <span class="text-gray-400 truncate flex-1 font-mono text-xs">{msg.input}</span>
                <%= if msg.is_error do %>
                  <span class="text-red-400 text-xs">error</span>
                <% end %>
              </button>
              <div class={"px-3 py-2 bg-gray-900 border-t border-gray-700 #{if msg.collapsed, do: "hidden", else: ""}"}>
                <div class="text-xs text-gray-500 mb-1">Input</div>
                <div class="whitespace-pre-wrap font-mono text-xs text-gray-300 mb-2">{msg.input}</div>
                <%= if msg.output do %>
                  <div class="text-xs text-gray-500 mb-1 mt-2">Output</div>
                  <div class={"whitespace-pre-wrap font-mono text-xs max-h-64 overflow-y-auto #{if msg.is_error, do: "text-red-400", else: "text-gray-300"}"}>{msg.output}</div>
                <% else %>
                  <div class="text-xs text-gray-500 italic">Running...</div>
                <% end %>
              </div>
            </div>
          <% else %>
            <div class={message_class(msg.type)}>
              <div class="text-xs text-gray-500 mb-1">{msg.type}</div>
              <%= if msg.type == :assistant do %>
                <div class="markdown-content text-sm">{raw(render_markdown(msg.content))}</div>
              <% else %>
                <div class="whitespace-pre-wrap font-mono text-sm">{msg.content}</div>
              <% end %>
            </div>
          <% end %>
        <% end %>
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
    """
  end

  # Helper functions

  defp toggle_tool_message(messages, id) do
    Enum.map(messages, fn msg ->
      if msg.id == id && msg.type == :tool_call, do: %{msg | collapsed: !msg.collapsed}, else: msg
    end)
  end

  defp apply_tool_result(messages, result) do
    Enum.map(messages, &update_tool_message(&1, result))
  end

  defp update_tool_message(%{type: :tool_call, tool_use_id: id} = msg, %{tool_use_id: id} = result) do
    output = extract_tool_output(result)
    %{msg | output: output, is_error: result.is_error}
  end

  defp update_tool_message(msg, _result), do: msg

  defp extract_tool_output(%{stderr: stderr}) when stderr != "", do: stderr
  defp extract_tool_output(%{stdout: stdout}) when stdout != "", do: stdout
  defp extract_tool_output(_result), do: "(no output)"

  defp add_message(socket, type, content) do
    message = %{
      id: System.unique_integer([:positive]),
      type: type,
      content: content,
      timestamp: DateTime.utc_now()
    }

    update(socket, :messages, fn messages -> messages ++ [message] end)
  end

  defp append_to_assistant_message(socket, text) do
    messages = socket.assigns.messages

    case List.last(messages) do
      %{type: :assistant} = last_msg ->
        updated_msg = %{last_msg | content: last_msg.content <> text}
        updated_messages = List.replace_at(messages, -1, updated_msg)
        assign(socket, :messages, updated_messages)

      _ ->
        add_message(socket, :assistant, text)
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
  defp status_color(:cloning), do: "text-blue-400"
  defp status_color(:starting_claude), do: "text-blue-400"
  defp status_color(:error), do: "text-red-400"
  defp status_color(:disconnected), do: "text-orange-400"
  defp status_color(_), do: "text-gray-400"

  defp status_text(:ready), do: "Ready"
  defp status_text(:processing), do: "Processing..."
  defp status_text(:connecting), do: "Connecting..."
  defp status_text(:cloning), do: "Cloning repo..."
  defp status_text(:starting_claude), do: "Starting Claude..."
  defp status_text(:error), do: "Error"
  defp status_text(:disconnected), do: "Disconnected"
  defp status_text(:initializing), do: "Initializing..."
  defp status_text(status), do: to_string(status)

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
end
