defmodule MiniMe.Sandbox.Client do
  @moduledoc """
  HTTP client for Sprites.dev API.

  Handles:
  - Creating and managing sandbox VMs
  - Executing commands via WebSocket
  - Managing checkpoints
  - URL exposure
  """
  require Logger

  @base_url "https://api.sprites.dev/v1"

  # Client API

  @doc """
  Create a new sprite sandbox.
  """
  def create_sprite(name, opts \\ []) do
    public = Keyword.get(opts, :public, true)

    body = %{
      name: name,
      url_settings: %{auth: if(public, do: "public", else: "sprite")}
    }

    case request(:post, "/sprites", body) do
      {:ok, %{status: status, body: sprite}} when status in [200, 201] ->
        {:ok, sprite}

      {:ok, %{status: 409}} ->
        # Already exists, fetch it
        get_sprite(name)

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all sprites for the current account.
  Returns a list of sprite objects with name, status, etc.
  """
  def list_sprites do
    case request(:get, "/sprites") do
      {:ok, %{status: 200, body: %{"sprites" => sprites}}} ->
        {:ok, sprites}

      {:ok, %{status: 200, body: sprites}} when is_list(sprites) ->
        # Fallback in case API returns plain list
        {:ok, sprites}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get sprite details.
  """
  def get_sprite(name) do
    case request(:get, "/sprites/#{name}") do
      {:ok, %{status: 200, body: sprite}} ->
        {:ok, sprite}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Suspend (hibernate) a sprite. This stops compute charges.
  The sprite will wake automatically on next request.
  """
  def suspend_sprite(name) do
    case request(:post, "/sprites/#{name}/suspend", %{}) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete a sprite.
  """
  def delete_sprite(name) do
    case request(:delete, "/sprites/#{name}") do
      {:ok, %{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute a simple command (non-interactive).
  Returns `{:ok, %{"output" => string, "exit_code" => integer}}` or `{:error, reason}`.

  The command can be either:
  - A string (will be wrapped with /bin/sh -c for shell interpretation)
  - A list of strings [executable, arg1, arg2, ...]
  """
  def exec(name, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    env = Keyword.get(opts, :env, [])

    # Build command parts - the API expects separate cmd query params
    cmd_parts = build_cmd_parts(command)

    # Build query string with cmd params and optional env/dir
    # Use encode_www_form to properly escape all special characters including @, ', etc.
    query_parts =
      Enum.map(cmd_parts, fn part -> "cmd=#{URI.encode_www_form(part)}" end) ++
        Enum.map(env, fn {k, v} -> "env=#{URI.encode_www_form("#{k}=#{v}")}" end)

    query = Enum.join(query_parts, "&")

    case request(:post, "/sprites/#{name}/exec?#{query}", nil, receive_timeout: timeout) do
      {:ok, %{status: 200, body: result}} ->
        {:ok, parse_exec_response(result)}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_cmd_parts(cmd) when is_list(cmd), do: cmd
  defp build_cmd_parts(cmd) when is_binary(cmd), do: ["/bin/sh", "-c", cmd]

  # Parse binary exec response from Sprites API
  # The API returns a binary stream with format: <stream_type><data>...<exit_marker><exit_code>
  # Stream types: 1=stdout, 2=stderr, 3=exit
  defp parse_exec_response(binary) when is_binary(binary) do
    parse_exec_chunks(binary, [])
  end

  defp parse_exec_response(other), do: other

  defp parse_exec_chunks(<<>>, acc) do
    %{"output" => IO.iodata_to_binary(Enum.reverse(acc)), "exit_code" => 0}
  end

  defp parse_exec_chunks(<<3, exit_code, _rest::binary>>, acc) do
    # Exit marker (type 3) followed by exit code
    %{"output" => IO.iodata_to_binary(Enum.reverse(acc)), "exit_code" => exit_code}
  end

  defp parse_exec_chunks(<<1, rest::binary>>, acc) do
    # Stdout (type 1) - read until next marker or end
    {chunk, remaining} = read_until_marker(rest)
    parse_exec_chunks(remaining, [chunk | acc])
  end

  defp parse_exec_chunks(<<2, rest::binary>>, acc) do
    # Stderr (type 2) - read until next marker or end
    {chunk, remaining} = read_until_marker(rest)
    parse_exec_chunks(remaining, [chunk | acc])
  end

  defp parse_exec_chunks(<<_unknown, rest::binary>>, acc) do
    # Skip unknown markers
    parse_exec_chunks(rest, acc)
  end

  defp read_until_marker(binary), do: read_until_marker(binary, [])

  defp read_until_marker(<<>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}

  defp read_until_marker(<<marker, _::binary>> = rest, acc) when marker in [1, 2, 3] do
    {IO.iodata_to_binary(Enum.reverse(acc)), rest}
  end

  defp read_until_marker(<<byte, rest::binary>>, acc) do
    read_until_marker(rest, [<<byte>> | acc])
  end

  @doc """
  Build WebSocket URL for interactive exec session.

  The `cmd` parameter can be either:
  - A string (will be wrapped with /bin/sh -c for shell interpretation)
  - A list of strings (executable and arguments, passed as separate cmd params)
  """
  def exec_websocket_url(name, cmd, opts \\ []) do
    # Build cmd params - the API expects separate cmd params for exec and each arg
    cmd_params = build_cmd_params(cmd)

    other_params =
      []
      |> maybe_add(:tty, Keyword.get(opts, :tty, true))
      |> maybe_add(:stdin, Keyword.get(opts, :stdin, true))
      |> maybe_add(:cols, Keyword.get(opts, :cols))
      |> maybe_add(:rows, Keyword.get(opts, :rows))

    # Build query string with potentially multiple cmd params
    # Use encode_www_form to properly escape all special characters
    cmd_query = Enum.map_join(cmd_params, "&", fn part -> "cmd=#{URI.encode_www_form(part)}" end)
    other_query = URI.encode_query(other_params)

    query =
      case {cmd_query, other_query} do
        {"", other} -> other
        {cmd, ""} -> cmd
        {cmd, other} -> cmd <> "&" <> other
      end

    "wss://api.sprites.dev/v1/sprites/#{name}/exec?#{query}"
  end

  defp build_cmd_params(cmd) when is_list(cmd), do: cmd
  defp build_cmd_params(cmd) when is_binary(cmd), do: ["/bin/sh", "-c", cmd]

  @doc """
  Create a checkpoint.
  """
  def create_checkpoint(name, comment \\ nil) do
    body = if comment, do: %{comment: comment}, else: %{}

    case request(:post, "/sprites/#{name}/checkpoint", body) do
      {:ok, %{status: 200, body: result}} ->
        {:ok, result}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List checkpoints for a sprite.
  """
  def list_checkpoints(name) do
    case request(:get, "/sprites/#{name}/checkpoints") do
      {:ok, %{status: 200, body: checkpoints}} ->
        {:ok, checkpoints}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Restore a checkpoint.
  """
  def restore_checkpoint(name, checkpoint_id) do
    case request(:post, "/sprites/#{name}/checkpoints/#{checkpoint_id}/restore", %{}) do
      {:ok, %{status: 200, body: result}} ->
        {:ok, result}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update sprite settings (e.g., make URL public).
  """
  def update_sprite(name, settings) do
    case request(:put, "/sprites/#{name}", settings) do
      {:ok, %{status: 200, body: sprite}} ->
        {:ok, sprite}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get the public URL for a sprite.
  """
  def sprite_url(name) do
    "https://#{name}.sprites.app"
  end

  # Private Functions

  defp request(method, path, body \\ nil, opts \\ []) do
    base_url = Application.get_env(:mini_me, :sprites_base_url, @base_url)

    req_opts =
      [
        method: method,
        url: base_url <> path,
        headers: [{"authorization", "Bearer #{token()}"}],
        # Suppress noisy retry warnings for transient connection issues
        retry_log_level: false
      ]
      |> maybe_add_json(body)
      |> Keyword.merge(opts)

    Req.request(req_opts)
  end

  defp maybe_add_json(opts, nil), do: opts
  defp maybe_add_json(opts, body), do: Keyword.put(opts, :json, body)

  defp maybe_add(params, _key, nil), do: params
  defp maybe_add(params, _key, false), do: params
  defp maybe_add(params, key, value), do: [{key, value} | params]

  defp token do
    Application.get_env(:mini_me, :sprites_token) ||
      raise "SPRITES_TOKEN environment variable is not set"
  end
end
