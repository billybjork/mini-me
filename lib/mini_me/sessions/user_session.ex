defmodule MiniMe.Sessions.UserSession do
  @moduledoc """
  GenServer managing a user session with a Sprite running Claude Code.

  This is the "Outer Loop" that:
  - Creates/manages sprite lifecycle
  - Holds the WebSocket connection to the sprite
  - Routes user messages to Claude Code
  - Broadcasts agent events to LiveView via PubSub
  """
  use GenServer
  require Logger

  alias MiniMe.Sandbox.{Client, Process}
  alias MiniMe.Sessions.Registry
  alias MiniMe.Workspaces
  alias MiniMe.Transform.Pipeline
  alias MiniMe.Chat

  @pubsub MiniMe.PubSub

  defstruct [
    :workspace,
    :process_pid,
    :execution_session_id,
    status: :initializing,
    message_queue: :queue.new()
  ]

  # Client API

  @doc """
  Start a new user session for a workspace.
  """
  def start_link(workspace) do
    GenServer.start_link(__MODULE__, workspace)
  end

  @doc """
  Send a message to Claude Code.
  """
  def send_message(pid, text) do
    GenServer.cast(pid, {:send_message, text})
  end

  @doc """
  Send interrupt signal to Claude Code.
  """
  def interrupt(pid) do
    GenServer.cast(pid, :interrupt)
  end

  @doc """
  Get current session status.
  """
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc """
  Get the current execution session ID (for message persistence).
  """
  def execution_session_id(pid) do
    GenServer.call(pid, :execution_session_id)
  end

  @doc """
  Get the PubSub topic for a workspace.
  """
  def pubsub_topic(workspace_id) do
    "session:#{workspace_id}"
  end

  # Server Implementation

  @impl true
  def init(workspace) do
    # Register in the registry
    Registry.register(workspace.id)

    state = %__MODULE__{
      workspace: workspace
    }

    # Start initialization asynchronously
    send(self(), :initialize)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, queued: :queue.len(state.message_queue)}, state}
  end

  def handle_call(:execution_session_id, _from, state) do
    # Use Map.get for backwards compatibility with old processes
    {:reply, Map.get(state, :execution_session_id), state}
  end

  @impl true
  def handle_cast({:send_message, text}, state) do
    Logger.debug("UserSession.send_message: status=#{state.status}, process_pid=#{inspect(state.process_pid)}, queue_len=#{:queue.len(state.message_queue)}")
    state = handle_user_message(text, state)
    Logger.debug("UserSession.send_message after handle: status=#{state.status}, process_pid=#{inspect(state.process_pid)}")
    {:noreply, state}
  end

  def handle_cast(:interrupt, state) do
    if state.process_pid do
      Process.interrupt(state.process_pid)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:initialize, state) do
    broadcast(state, {:session_status, :connecting})

    case setup_sprite(state.workspace) do
      {:ok, updated_workspace} ->
        state = %{state | workspace: updated_workspace}
        broadcast(state, {:session_status, :cloning})

        case clone_repo(state.workspace) do
          :ok ->
            broadcast(state, {:session_status, :starting_claude})
            start_claude_code(state)

          {:error, reason} ->
            Logger.error("Failed to clone repo: #{inspect(reason)}")
            Workspaces.update_status(state.workspace, "error", inspect(reason))
            broadcast(state, {:agent_error, "Failed to clone repository"})
            {:noreply, %{state | status: :error}}
        end

      {:error, reason} ->
        Logger.error("Failed to setup sprite: #{inspect(reason)}")
        Workspaces.update_status(state.workspace, "error", inspect(reason))
        broadcast(state, {:agent_error, "Failed to create sandbox"})
        {:noreply, %{state | status: :error}}
    end
  end

  # Agent status updates from Sandbox.Process
  def handle_info({:agent_status, :connected}, state) do
    Logger.info("Claude Code connected for workspace #{state.workspace.id}")
    Workspaces.update_status(state.workspace, "ready")

    # Start a new execution session
    {:ok, session} = Chat.start_execution_session(state.workspace.id, "claude_code")
    broadcast(state, {:execution_session_started, session.id})
    broadcast(state, {:session_status, :ready})

    state = %{state | status: :ready, execution_session_id: session.id}
    state = process_queued_messages(state)
    {:noreply, state}
  end

  def handle_info({:agent_status, :disconnected}, state) do
    Logger.warning("Claude Code disconnected for workspace #{state.workspace.id}")
    broadcast(state, {:session_status, :disconnected})
    {:noreply, %{state | status: :disconnected}}
  end

  def handle_info({:agent_status, {:terminated, reason}}, state) do
    Logger.info("Claude Code terminated: #{inspect(reason)}")

    # Complete the execution session as interrupted
    if state.execution_session_id do
      Chat.complete_execution_session(state.execution_session_id, "interrupted")
      broadcast(state, {:execution_session_ended, state.execution_session_id, "interrupted"})
    end

    broadcast(state, {:agent_error, "Session ended"})
    {:stop, :normal, state}
  end

  # Agent events from Sandbox.Process
  def handle_info({:agent_event, event}, state) do
    state = handle_agent_event(event, state)
    {:noreply, state}
  end

  def handle_info({:agent_output, text}, state) do
    # Plain text output (not NDJSON)
    transformed = Pipeline.transform(text)

    if transformed != "" do
      broadcast(state, {:agent_text, transformed})
    end

    {:noreply, state}
  end

  def handle_info({:agent_stderr, text}, state) do
    Logger.warning("Claude Code stderr: #{text}")
    {:noreply, state}
  end

  def handle_info({:agent_exit, code}, state) do
    Logger.info("Claude Code exited with code #{code}")

    # Complete the execution session
    if state.execution_session_id do
      status = if code == 0, do: "completed", else: "failed"
      Chat.complete_execution_session(state.execution_session_id, status)
      broadcast(state, {:execution_session_ended, state.execution_session_id, status})
    end

    broadcast(state, {:agent_done})
    # Don't nil process_pid - the WebSockex (Sandbox.Process) is still alive
    # and will reconnect, restarting Claude Code
    {:noreply, %{state | status: :exited, execution_session_id: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("UserSession received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("UserSession terminating: #{inspect(reason)}")

    # Clean up the sprite process if running
    if state.process_pid && Elixir.Process.alive?(state.process_pid) do
      GenServer.stop(state.process_pid, :normal)
    end

    :ok
  end

  # Private Functions

  defp setup_sprite(workspace) do
    Logger.info("Setting up sprite for workspace #{workspace.id}")
    Workspaces.update_status(workspace, "creating")

    case Client.create_sprite(workspace.sprite_name) do
      {:ok, _sprite} ->
        {:ok, workspace}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clone_repo(workspace) do
    Logger.info("Checking/cloning repo #{workspace.github_repo_name}")
    Workspaces.update_status(workspace, "cloning")

    # Configure git credentials for GitHub (enables clone, pull, push)
    :ok = configure_git_credentials(workspace.sprite_name)

    # Check if repo is already cloned
    case Client.exec(workspace.sprite_name, "test -d #{workspace.working_dir}/.git") do
      {:ok, %{"exit_code" => 0}} ->
        # Repo already exists, just pull latest
        Logger.info("Repo already cloned, pulling latest")

        case Client.exec(workspace.sprite_name, "cd #{workspace.working_dir} && git pull",
               timeout: 120_000
             ) do
          {:ok, %{"exit_code" => 0}} -> :ok
          {:ok, %{"exit_code" => _, "output" => output}} -> {:error, output}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        # Clone the repo
        clone_cmd = "git clone #{workspace.github_repo_url} #{workspace.working_dir}"

        case Client.exec(workspace.sprite_name, clone_cmd, timeout: 300_000) do
          {:ok, %{"exit_code" => 0}} -> :ok
          {:ok, %{"exit_code" => _, "output" => output}} -> {:error, output}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp configure_git_credentials(sprite_name) do
    github_token = Application.get_env(:mini_me, :github_token)

    if github_token do
      # Configure git to use token for all GitHub HTTPS operations
      # This enables clone, pull, push without modifying URLs
      git_config_cmd =
        "git config --global credential.helper store && " <>
          "git config --global user.email 'sprite@mini-me.dev' && " <>
          "git config --global user.name 'Mini Me Sprite' && " <>
          "echo 'https://x-access-token:#{github_token}@github.com' > ~/.git-credentials"

      case Client.exec(sprite_name, git_config_cmd) do
        {:ok, %{"exit_code" => 0}} ->
          Logger.info("Git credentials configured for sprite")
          :ok

        {:ok, %{"exit_code" => _, "output" => output}} ->
          Logger.warning("Failed to configure git credentials: #{output}")
          # Continue anyway, public repos will still work
          :ok

        {:error, reason} ->
          Logger.warning("Failed to configure git credentials: #{inspect(reason)}")
          :ok
      end
    else
      Logger.debug("No GitHub token configured, skipping credential setup")
      :ok
    end
  end

  defp start_claude_code(state) do
    Logger.info("Starting Claude Code for workspace #{state.workspace.id}")

    case Process.start_link(
           sprite_name: state.workspace.sprite_name,
           session_pid: self(),
           working_dir: state.workspace.working_dir,
           repo_name: state.workspace.github_repo_name
         ) do
      {:ok, pid} ->
        {:noreply, %{state | process_pid: pid, status: :connecting}}

      {:error, reason} ->
        Logger.error("Failed to start Claude Code: #{inspect(reason)}")
        Workspaces.update_status(state.workspace, "error", inspect(reason))
        broadcast(state, {:agent_error, "Failed to start Claude Code"})
        {:noreply, %{state | status: :error}}
    end
  end

  defp restart_claude_code(state) do
    # Stop old process if still alive
    if state.process_pid && Elixir.Process.alive?(state.process_pid) do
      GenServer.stop(state.process_pid, :normal)
    end

    broadcast(state, {:session_status, :starting_claude})

    case Process.start_link(
           sprite_name: state.workspace.sprite_name,
           session_pid: self(),
           working_dir: state.workspace.working_dir,
           repo_name: state.workspace.github_repo_name
         ) do
      {:ok, pid} ->
        %{state | process_pid: pid, status: :connecting}

      {:error, reason} ->
        Logger.error("Failed to restart Claude Code: #{inspect(reason)}")
        broadcast(state, {:agent_error, "Failed to reconnect: #{inspect(reason)}"})
        %{state | status: :error}
    end
  end

  defp handle_user_message(text, state) do
    case state.status do
      :ready ->
        dispatch_message(text, state)

      :processing ->
        queue_message(text, state)

      status when status in [:disconnected, :exited] ->
        # Queue message and restart Claude Code to wake the sprite
        state = queue_message(text, state)
        Logger.info("Session #{status}, restarting Claude Code for queued message")
        restart_claude_code(state)

      _ ->
        queue_message(text, state)
    end
  end

  defp dispatch_message(text, state) do
    if state.process_pid do
      case Process.send_message(state.process_pid, text) do
        :ok ->
          broadcast(state, {:session_status, :processing})
          %{state | status: :processing}

        {:error, reason} ->
          Logger.error("Failed to send message: #{inspect(reason)}")
          broadcast(state, {:agent_error, "Failed to send message"})
          state
      end
    else
      queue_message(text, state)
    end
  end

  defp queue_message(text, state) do
    queue = :queue.in(text, state.message_queue)
    %{state | message_queue: queue}
  end

  defp process_queued_messages(state) do
    case :queue.out(state.message_queue) do
      {{:value, text}, rest} ->
        state = %{state | message_queue: rest}
        dispatch_message(text, state)

      {:empty, _} ->
        state
    end
  end

  defp handle_agent_event(%{type: :system_init}, state) do
    Logger.debug("Claude Code initialized")
    state
  end

  defp handle_agent_event(%{type: :assistant_message, text: text, tool_uses: tool_uses}, state) do
    # Broadcast text if any
    if text != "" do
      transformed = Pipeline.strip_ansi(text)
      broadcast(state, {:agent_text, transformed})
    end

    # Broadcast tool uses
    Enum.each(tool_uses, fn tool ->
      broadcast(state, {:tool_use, tool})
    end)

    state
  end

  defp handle_agent_event(%{type: :tool_result} = result, state) do
    broadcast(state, {:tool_result, result})
    state
  end

  defp handle_agent_event(%{type: :message_stop}, state) do
    broadcast(state, {:agent_done})
    broadcast(state, {:session_status, :ready})
    process_queued_messages(%{state | status: :ready})
  end

  defp handle_agent_event(event, state) do
    Logger.debug("Unhandled agent event: #{inspect(event)}")
    state
  end

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(@pubsub, pubsub_topic(state.workspace.id), message)
  end
end
