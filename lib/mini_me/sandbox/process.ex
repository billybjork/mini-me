defmodule MiniMe.Sandbox.Process do
  @moduledoc """
  Manages a WebSocket connection to a Sprite for Claude Code execution.

  Uses Claude Code's streaming JSON input/output mode for continuous interaction:
  - Input: NDJSON messages via stdin
  - Output: NDJSON events via stdout
  """
  use WebSockex
  require Logger

  alias MiniMe.Sandbox.Client

  defstruct [:sprite_name, :session_pid, :buffer, :status]

  # Client API

  @doc """
  Start a new Claude Code process in a sprite sandbox.
  """
  def start_link(opts) do
    sprite_name = Keyword.fetch!(opts, :sprite_name)
    session_pid = Keyword.fetch!(opts, :session_pid)
    working_dir = Keyword.get(opts, :working_dir, "/home/sprite")

    cmd = build_claude_command(working_dir)
    url = Client.exec_websocket_url(sprite_name, cmd, tty: false, stdin: true)

    state = %__MODULE__{
      sprite_name: sprite_name,
      session_pid: session_pid,
      buffer: "",
      status: :starting
    }

    headers = [{"Authorization", "Bearer #{token()}"}]
    WebSockex.start_link(url, __MODULE__, state, extra_headers: headers)
  end

  @doc """
  Send a message to the Claude Code agent.
  """
  def send_message(pid, message) do
    json = Jason.encode!(%{type: "user", message: %{role: "user", content: message}})
    WebSockex.send_frame(pid, {:binary, json <> "\n"})
  end

  @doc """
  Send interrupt signal (SIGINT) to the agent.
  """
  def interrupt(pid) do
    WebSockex.send_frame(pid, {:binary, <<3>>})
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Connected to Sprite #{state.sprite_name} for Claude Code execution")
    send(state.session_pid, {:agent_status, :connected})
    {:ok, %{state | status: :connected}}
  end

  @impl true
  def handle_frame({:binary, data}, state) do
    case data do
      <<1, payload::binary>> ->
        handle_stdout(payload, state)

      <<2, payload::binary>> ->
        handle_stderr(payload, state)

      <<3, exit_code>> ->
        handle_exit(exit_code, state)

      _ ->
        Logger.debug("Unknown frame: #{inspect(data)}")
        {:ok, state}
    end
  end

  def handle_frame({:text, text}, state) do
    Logger.debug("Text frame: #{text}")
    {:ok, state}
  end

  @impl true
  def handle_disconnect(disconnect_map, state) do
    Logger.warning("Disconnected from Sprite: #{inspect(disconnect_map)}")
    send(state.session_pid, {:agent_status, :disconnected})
    {:reconnect, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Sprite process terminating: #{inspect(reason)}")
    send(state.session_pid, {:agent_status, {:terminated, reason}})
  end

  # Private Functions

  defp build_claude_command(working_dir) do
    oauth_token = Application.get_env(:mini_me, :claude_oauth_token)

    env_prefix =
      if oauth_token do
        "CLAUDE_CODE_OAUTH_TOKEN=#{oauth_token} "
      else
        ""
      end

    "cd #{working_dir} && #{env_prefix}claude --print --input-format stream-json --output-format stream-json --verbose"
  end

  defp handle_stdout(payload, state) do
    buffer = state.buffer <> payload
    {lines, remaining} = extract_complete_lines(buffer)

    Enum.each(lines, fn line ->
      case parse_ndjson_event(line) do
        {:ok, event} ->
          send(state.session_pid, {:agent_event, event})

        {:error, _} ->
          send(state.session_pid, {:agent_output, line})
      end
    end)

    {:ok, %{state | buffer: remaining}}
  end

  defp handle_stderr(payload, state) do
    Logger.warning("Claude Code stderr: #{payload}")
    send(state.session_pid, {:agent_stderr, payload})
    {:ok, state}
  end

  defp handle_exit(exit_code, state) do
    Logger.info("Claude Code exited with code: #{exit_code}")
    send(state.session_pid, {:agent_exit, exit_code})
    {:ok, %{state | status: :exited}}
  end

  defp extract_complete_lines(buffer) do
    case String.split(buffer, "\n", parts: :infinity) do
      [single] ->
        {[], single}

      parts ->
        {complete, [remaining]} = Enum.split(parts, -1)
        {complete, remaining}
    end
  end

  defp parse_ndjson_event(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = event} ->
        {:ok, normalize_event(type, event)}

      {:ok, other} ->
        {:ok, %{type: :unknown, data: other}}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_event("system", %{"subtype" => "init"} = event),
    do: %{type: :system_init, data: event}

  defp normalize_event("assistant", %{"message" => %{"content" => content}}) do
    text =
      content
      |> Enum.map_join("", fn
        %{"type" => "text", "text" => t} -> t
        %{"type" => "tool_use", "name" => name} -> "[Using tool: #{name}]"
        _ -> ""
      end)

    %{type: :assistant_message, text: text}
  end

  defp normalize_event("result", event),
    do: %{type: :message_stop, data: event}

  defp normalize_event(type, event),
    do: %{type: String.to_atom(type), data: event}

  defp token do
    Application.get_env(:mini_me, :sprites_token) ||
      raise "SPRITES_TOKEN environment variable is not set"
  end
end
