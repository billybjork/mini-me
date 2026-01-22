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
    repo_name = Keyword.get(opts, :repo_name)

    cmd = build_claude_command(working_dir, repo_name)
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
  def handle_disconnect(%{reason: %WebSockex.RequestError{code: 404}} = disconnect_map, state) do
    # Sprite doesn't exist - don't reconnect
    Logger.warning("Sprite not found (404), stopping: #{inspect(disconnect_map)}")
    send(state.session_pid, {:agent_status, :disconnected})
    {:ok, state}
  end

  def handle_disconnect(disconnect_map, state) do
    Logger.warning("Disconnected from Sprite: #{inspect(disconnect_map)}")
    send(state.session_pid, {:agent_status, :disconnected})
    {:reconnect, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Sprite process terminating: #{inspect(reason)}")

    # Kill the Claude process on the sprite to allow it to hibernate
    Task.start(fn ->
      Client.exec(state.sprite_name, "pkill -f 'claude --print' || true", timeout: 5_000)
    end)

    send(state.session_pid, {:agent_status, {:terminated, reason}})
  end

  # Private Functions

  defp build_claude_command(working_dir, repo_name) do
    oauth_token = Application.get_env(:mini_me, :claude_oauth_token)

    env_prefix =
      if oauth_token do
        "CLAUDE_CODE_OAUTH_TOKEN=#{oauth_token} "
      else
        ""
      end

    # Provide context about the task's repository via system prompt
    context_prompt =
      if repo_name do
        escaped = String.replace(repo_name, "'", "'\\''")
        " --append-system-prompt 'You are working in the #{escaped} repository.'"
      else
        ""
      end

    "cd #{working_dir} && #{env_prefix}claude --print --input-format stream-json --output-format stream-json --verbose#{context_prompt}"
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
    # Separate text content from tool uses
    {text_parts, tool_uses} =
      Enum.reduce(content, {[], []}, fn item, {texts, tools} ->
        case item do
          %{"type" => "text", "text" => t} ->
            {[t | texts], tools}

          %{"type" => "tool_use", "name" => name, "id" => id} = tool ->
            input = Map.get(tool, "input", %{})
            {texts, [%{id: id, name: name, input: input} | tools]}

          _ ->
            {texts, tools}
        end
      end)

    text = text_parts |> Enum.reverse() |> Enum.join("")
    tool_uses = Enum.reverse(tool_uses)

    %{type: :assistant_message, text: text, tool_uses: tool_uses}
  end

  defp normalize_event("user", %{"tool_use_result" => result, "message" => message}) do
    # Extract tool_use_id from the message content
    tool_use_id =
      case message do
        %{"content" => [%{"tool_use_id" => id} | _]} -> id
        _ -> nil
      end

    Logger.debug("Tool result raw: #{inspect(result)}")

    # Extract output from various possible formats
    {output, stderr, is_error} = extract_tool_output(result)

    Logger.debug("Extracted output: #{inspect(String.slice(output || "", 0, 100))}")

    %{
      type: :tool_result,
      tool_use_id: tool_use_id,
      stdout: output,
      stderr: stderr,
      is_error: is_error
    }
  end

  defp normalize_event("result", event),
    do: %{type: :message_stop, data: event}

  # Known event types from Claude Code streaming output
  @known_event_types %{
    "system" => :system,
    "assistant" => :assistant,
    "user" => :user,
    "result" => :result,
    "error" => :error,
    "content_block_start" => :content_block_start,
    "content_block_delta" => :content_block_delta,
    "content_block_stop" => :content_block_stop,
    "message_start" => :message_start,
    "message_delta" => :message_delta,
    "message_stop" => :message_stop
  }

  defp normalize_event(type, event) do
    atom_type = Map.get(@known_event_types, type, :unknown)
    %{type: atom_type, data: event, original_type: type}
  end

  # Extract output from tool results which can come in various formats
  defp extract_tool_output(result) when is_binary(result) do
    # String result - could be content or error, assume content
    {result, "", false}
  end

  defp extract_tool_output(result) when is_map(result) do
    is_error = Map.get(result, "isError", false)
    stderr = Map.get(result, "stderr", "")

    # Try various keys where content might be stored
    # Read tool uses: %{"file" => %{"content" => "..."}, "type" => "text"}
    # Bash tool uses: %{"stdout" => "...", "stderr" => "..."}
    content =
      get_in(result, ["file", "content"]) ||
        Map.get(result, "content") ||
        Map.get(result, "output") ||
        Map.get(result, "stdout") ||
        Map.get(result, "result") ||
        Map.get(result, "text") ||
        ""

    # Handle content that might be an array of content blocks
    content = normalize_content(content)

    {content, stderr, is_error}
  end

  defp extract_tool_output(result) do
    # Unknown format, convert to string
    {inspect(result), "", true}
  end

  # Normalize content which might be a string or array of content blocks
  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{"type" => "text", "text" => text} -> text
      %{"text" => text} -> text
      item when is_binary(item) -> item
      item -> inspect(item)
    end)
  end

  defp normalize_content(content) when is_map(content) do
    Map.get(content, "text", inspect(content))
  end

  defp normalize_content(nil), do: ""
  defp normalize_content(content), do: inspect(content)

  defp token do
    Application.get_env(:mini_me, :sprites_token) ||
      raise "SPRITES_TOKEN environment variable is not set"
  end
end
