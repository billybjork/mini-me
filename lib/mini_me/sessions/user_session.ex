defmodule MiniMe.Sessions.UserSession do
  @moduledoc """
  GenServer managing a user session with a Sprite running Claude Code.

  This is the "Outer Loop" that:
  - Allocates sprites via SpriteAllocator
  - Holds the WebSocket connection to the sprite
  - Routes user messages to Claude Code
  - Broadcasts agent events to LiveView via PubSub
  - Manages task status transitions
  """
  use GenServer
  require Logger

  alias MiniMe.Sandbox.{Allocator, Process}
  alias MiniMe.Sessions.Registry
  alias MiniMe.Tasks
  alias MiniMe.Transform.Pipeline
  alias MiniMe.Chat

  @pubsub MiniMe.PubSub
  # Idle timeout before stopping Claude to let sprite sleep (2 minutes)
  @idle_timeout :timer.minutes(2)

  defstruct [
    :task,
    :sprite_name,
    :working_dir,
    :process_pid,
    :execution_session_id,
    :idle_timer,
    status: :initializing,
    message_queue: :queue.new()
  ]

  # Client API

  @doc """
  Start a new user session for a task.
  Task should have repo preloaded if it has one.
  """
  def start_link(task) do
    GenServer.start_link(__MODULE__, task)
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
  Get the PubSub topic for a task.
  """
  def pubsub_topic(task_id) do
    "session:#{task_id}"
  end

  # Server Implementation

  @impl true
  def init(task) do
    # Register in the registry
    Registry.register(task.id)

    state = %__MODULE__{
      task: task
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
    {:reply, Map.get(state, :execution_session_id), state}
  end

  @impl true
  def handle_cast({:send_message, text}, state) do
    Logger.debug(
      "UserSession.send_message: status=#{state.status}, process_pid=#{inspect(state.process_pid)}"
    )

    state = handle_user_message(text, state)
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

    # Use SpriteAllocator to get a sprite and ensure repo is cloned
    case Allocator.allocate(state.task) do
      {:ok, %{sprite_name: sprite_name, working_dir: working_dir}} ->
        Logger.info("Allocated sprite #{sprite_name} for task #{state.task.id}")
        Tasks.mark_active(state.task)

        state = %{state | sprite_name: sprite_name, working_dir: working_dir}
        broadcast(state, {:session_status, :starting_claude})
        start_claude_code(state)

      {:error, {:repo_locked, other_task_id}} ->
        Logger.warning("Repo locked by task #{other_task_id}")
        broadcast(state, {:agent_error, "Repository is in use by another task"})
        {:noreply, %{state | status: :error}}

      {:error, reason} ->
        Logger.error("Failed to allocate sprite: #{inspect(reason)}")
        broadcast(state, {:agent_error, "Failed to create sandbox"})
        {:noreply, %{state | status: :error}}
    end
  end

  # Agent status updates from Sandbox.Process
  def handle_info({:agent_status, :connected}, state) do
    Logger.info("Claude Code connected for task #{state.task.id}")

    # Start a new execution session, tracking which sprite is used
    {:ok, session} = Chat.start_execution_session(state.task.id, state.sprite_name, "claude_code")
    broadcast(state, {:execution_session_started, session.id})
    broadcast(state, {:session_status, :ready})

    state = %{state | status: :ready, execution_session_id: session.id}
    state = process_queued_messages(state)
    {:noreply, state}
  end

  def handle_info({:agent_status, :disconnected}, state) do
    Logger.warning("Claude Code disconnected for task #{state.task.id}")
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

    # Update task status
    Tasks.mark_awaiting_input(state.task)

    broadcast(state, {:agent_done})
    {:noreply, %{state | status: :exited, execution_session_id: nil}}
  end

  def handle_info(:idle_timeout, state) do
    Logger.info("Idle timeout - stopping Claude to let sprite sleep")

    # Update task to idle
    Tasks.mark_idle(state.task)

    # Stop the Sandbox.Process (which will kill Claude)
    if state.process_pid && Elixir.Process.alive?(state.process_pid) do
      GenServer.stop(state.process_pid, :normal)
    end

    broadcast(state, {:session_status, :idle})
    {:noreply, %{state | status: :idle, process_pid: nil, idle_timer: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("UserSession received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("UserSession terminating: #{inspect(reason)}")

    # Release the sprite allocation
    Allocator.release(state.task)

    # Mark task as idle
    Tasks.mark_idle(state.task)

    # Clean up the sprite process if running
    if state.process_pid && Elixir.Process.alive?(state.process_pid) do
      GenServer.stop(state.process_pid, :normal)
    end

    :ok
  end

  # Private Functions

  defp start_claude_code(state) do
    repo_name = state.task.repo && state.task.repo.github_name

    Logger.info("Starting Claude Code for task #{state.task.id} on sprite #{state.sprite_name}")

    case Process.start_link(
           sprite_name: state.sprite_name,
           session_pid: self(),
           working_dir: state.working_dir,
           repo_name: repo_name
         ) do
      {:ok, pid} ->
        {:noreply, %{state | process_pid: pid, status: :connecting}}

      {:error, reason} ->
        Logger.error("Failed to start Claude Code: #{inspect(reason)}")
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

    repo_name = state.task.repo && state.task.repo.github_name

    case Process.start_link(
           sprite_name: state.sprite_name,
           session_pid: self(),
           working_dir: state.working_dir,
           repo_name: repo_name
         ) do
      {:ok, pid} ->
        Tasks.mark_active(state.task)
        %{state | process_pid: pid, status: :connecting}

      {:error, reason} ->
        Logger.error("Failed to restart Claude Code: #{inspect(reason)}")
        broadcast(state, {:agent_error, "Failed to reconnect: #{inspect(reason)}"})
        %{state | status: :error}
    end
  end

  defp handle_user_message(text, state) do
    # Cancel idle timer on any user activity
    state = cancel_idle_timer(state)

    case state.status do
      :ready ->
        dispatch_message(text, state)

      :processing ->
        queue_message(text, state)

      status when status in [:disconnected, :exited, :idle] ->
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
          Tasks.mark_active(state.task)
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

    # Update task status
    Tasks.mark_awaiting_input(state.task)

    # Start idle timer - will stop Claude if no activity
    state = cancel_idle_timer(state)
    timer = Elixir.Process.send_after(self(), :idle_timeout, @idle_timeout)

    process_queued_messages(%{state | status: :ready, idle_timer: timer})
  end

  defp handle_agent_event(event, state) do
    Logger.debug("Unhandled agent event: #{inspect(event)}")
    state
  end

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(@pubsub, pubsub_topic(state.task.id), message)
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: timer} = state) do
    Elixir.Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end
end
