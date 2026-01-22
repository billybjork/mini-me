defmodule MiniMe.Auth.ClaudeTokenManager do
  @moduledoc """
  Manages Claude OAuth token lifecycle with automatic refresh.

  ## Why This Exists

  Claude's OAuth uses short-lived access tokens (~1 hour) for security. When using
  a Claude Max subscription via OAuth (rather than API keys), the access token
  expires frequently. This module handles automatic token refresh using the
  long-lived refresh token, so the application doesn't need manual intervention.

  ## Token Types

  - **Access Token** (`sk-ant-oat01-...`): Short-lived (~1 hour), used for API calls.
    This is what gets passed to Claude Code via `CLAUDE_CODE_OAUTH_TOKEN`.

  - **Refresh Token** (`sk-ant-ort01-...`): Long-lived (days/weeks), used to obtain
    new access tokens. Never sent to Claude Code directly.

  ## How It Works

  1. On startup, loads tokens from database (or seeds from environment on first run)
  2. Before each API call, checks if access token is expired or expiring soon
  3. If expired, uses refresh token to get a new access token from Anthropic
  4. Persists the new token to the database

  ## Multi-User Support

  Currently operates as a singleton (single global token). The schema includes a
  `user_id` field for future multi-user support where each user would have their
  own Claude Max subscription and tokens.

  ## Usage

      # Get a valid access token (auto-refreshes if needed)
      {:ok, token} = ClaudeTokenManager.get_access_token()

      # Manually refresh (useful if you get a 401)
      {:ok, token} = ClaudeTokenManager.force_refresh()
  """

  use GenServer
  require Logger

  alias MiniMe.Auth.ClaudeToken
  alias MiniMe.Repo

  # Refresh token 5 minutes before expiry to avoid race conditions
  @refresh_buffer_ms 5 * 60 * 1000

  # Anthropic OAuth configuration
  # The token endpoint and client_id are used for the OAuth refresh flow.
  # The client_id is Claude Code's public OAuth client identifier - it's not
  # a secret and is the same for all Claude Code installations.
  @token_endpoint "https://console.anthropic.com/v1/oauth/token"
  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a valid access token, refreshing if necessary.

  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  def get_access_token do
    GenServer.call(__MODULE__, :get_access_token)
  end

  @doc """
  Forces a token refresh, regardless of expiry time.

  Useful when you receive a 401 from the API, indicating the token
  was revoked or expired early.
  """
  def force_refresh do
    GenServer.call(__MODULE__, :force_refresh, 30_000)
  end

  @doc """
  Seeds the token manager with initial credentials.

  Call this on first setup or when updating credentials. The tokens are
  persisted to the database for use across restarts.

  ## Parameters

  - `access_token`: The OAuth access token (sk-ant-oat01-...)
  - `refresh_token`: The OAuth refresh token (sk-ant-ort01-...)
  - `expires_at`: Unix timestamp in milliseconds when access token expires
  - `opts`: Optional keyword list with `:scopes` and `:subscription_type`
  """
  def seed_tokens(access_token, refresh_token, expires_at, opts \\ []) do
    GenServer.call(__MODULE__, {:seed_tokens, access_token, refresh_token, expires_at, opts})
  end

  @doc """
  Returns the current token state for debugging.
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Seeds tokens from the JSON stored in macOS keychain.

  This is the easiest way to set up tokens. Run this in IEx:

      # Get the JSON from keychain
      json = System.cmd("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]) |> elem(0)
      MiniMe.Auth.ClaudeTokenManager.seed_from_keychain_json(json)

  Or as a one-liner:

      System.cmd("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]) |> elem(0) |> MiniMe.Auth.ClaudeTokenManager.seed_from_keychain_json()

  The JSON format from Claude's keychain entry looks like:

      {
        "claudeAiOauth": {
          "accessToken": "sk-ant-oat01-...",
          "refreshToken": "sk-ant-ort01-...",
          "expiresAt": 1769135108883,
          "scopes": ["user:inference", ...],
          "subscriptionType": "max"
        }
      }
  """
  def seed_from_keychain_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"claudeAiOauth" => oauth_data}} ->
        access_token = Map.get(oauth_data, "accessToken")
        refresh_token = Map.get(oauth_data, "refreshToken")
        expires_at = Map.get(oauth_data, "expiresAt")
        scopes = Map.get(oauth_data, "scopes", [])
        subscription_type = Map.get(oauth_data, "subscriptionType", "max")

        if access_token && refresh_token && expires_at do
          seed_tokens(access_token, refresh_token, expires_at,
            scopes: scopes,
            subscription_type: subscription_type
          )
        else
          {:error, :missing_required_fields}
        end

      {:ok, _} ->
        {:error, :invalid_format}

      {:error, reason} ->
        {:error, {:json_parse_error, reason}}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Load token from database on startup
    state = load_or_init_token()
    {:ok, state}
  end

  @impl true
  def handle_call(:get_access_token, _from, state) do
    case ensure_valid_token(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.access_token}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:force_refresh, _from, state) do
    case refresh_token(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.access_token}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:seed_tokens, access_token, refresh_token, expires_at, opts}, _from, _state) do
    # Convert Unix ms timestamp to DateTime
    expires_at_dt = DateTime.from_unix!(expires_at, :millisecond)

    attrs = %{
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: expires_at_dt,
      scopes: Keyword.get(opts, :scopes, []),
      subscription_type: Keyword.get(opts, :subscription_type, "max")
    }

    case upsert_token(attrs) do
      {:ok, token} ->
        new_state = token_to_state(token)
        Logger.info("Claude OAuth tokens seeded successfully, expires at #{expires_at_dt}")
        {:reply, :ok, new_state}

      {:error, changeset} ->
        {:reply, {:error, changeset}, %{}}
    end
  end

  def handle_call(:get_state, _from, state) do
    # Return state with tokens partially redacted for safety
    redacted =
      state
      |> Map.update(:access_token, nil, &redact_token/1)
      |> Map.update(:refresh_token, nil, &redact_token/1)

    {:reply, redacted, state}
  end

  # Private Functions

  defp load_or_init_token do
    case Repo.one(ClaudeToken.global_token_query()) do
      nil ->
        # No token in DB - try to seed from environment variable (first-run migration path)
        maybe_seed_from_env()

      token ->
        Logger.debug("Loaded Claude OAuth token from database")
        token_to_state(token)
    end
  end

  defp maybe_seed_from_env do
    # Check for legacy single-token env var (backwards compatibility)
    # In the future, users should run a seed command instead
    case Application.get_env(:mini_me, :claude_oauth_token) do
      nil ->
        Logger.warning("""
        No Claude OAuth token found in database or environment.
        Run the seed command with your tokens from ~/.claude keychain.
        """)

        %{}

      _token ->
        # Legacy env var only has access token, not refresh token
        # User needs to provide full credentials
        Logger.warning("""
        Found legacy CLAUDE_CODE_OAUTH_TOKEN env var, but it doesn't include refresh token.
        Please seed complete OAuth credentials using:

          MiniMe.Auth.ClaudeTokenManager.seed_tokens(access_token, refresh_token, expires_at)

        You can get these from your local keychain:

          security find-generic-password -s "Claude Code-credentials" -w
        """)

        %{}
    end
  end

  defp token_to_state(%ClaudeToken{} = token) do
    %{
      id: token.id,
      access_token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: token.expires_at,
      scopes: token.scopes,
      subscription_type: token.subscription_type
    }
  end

  defp ensure_valid_token(%{access_token: nil}) do
    {:error, :no_token_configured}
  end

  defp ensure_valid_token(state) do
    if token_expired_or_expiring?(state) do
      Logger.info("Claude OAuth token expired or expiring soon, refreshing...")
      refresh_token(state)
    else
      {:ok, state}
    end
  end

  defp token_expired_or_expiring?(%{expires_at: nil}), do: true

  defp token_expired_or_expiring?(%{expires_at: expires_at}) do
    now = DateTime.utc_now()
    buffer = @refresh_buffer_ms / 1000

    case DateTime.diff(expires_at, now) do
      diff when diff <= buffer -> true
      _ -> false
    end
  end

  defp refresh_token(%{refresh_token: nil}) do
    {:error, :no_refresh_token}
  end

  defp refresh_token(state) do
    Logger.info("Refreshing Claude OAuth token...")

    # Anthropic's OAuth token endpoint expects JSON with the client_id.
    # The client_id is Claude Code's public OAuth identifier (not a secret).
    body =
      Jason.encode!(%{
        "grant_type" => "refresh_token",
        "refresh_token" => state.refresh_token,
        "client_id" => @client_id
      })

    headers = [
      {"Content-Type", "application/json"}
    ]

    case Req.post(@token_endpoint, body: body, headers: headers) do
      {:ok, %{status: 200, body: response_body}} ->
        handle_refresh_response(response_body, state)

      {:ok, %{status: status, body: body}} ->
        Logger.error("Token refresh failed with status #{status}: #{inspect(body)}")
        {:error, {:refresh_failed, status, body}}

      {:error, reason} ->
        Logger.error("Token refresh request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp handle_refresh_response(response, state) do
    # Anthropic OAuth response format:
    # {
    #   "access_token": "sk-ant-oat01-...",
    #   "refresh_token": "sk-ant-ort01-...",  # May be new or same
    #   "expires_in": 3600,  # Seconds until expiry
    #   "token_type": "bearer"
    # }

    access_token = Map.get(response, "access_token")
    # Refresh token may be rotated, use new one if provided
    refresh_token = Map.get(response, "refresh_token", state.refresh_token)
    expires_in = Map.get(response, "expires_in", 3600)

    if is_nil(access_token) do
      Logger.error("Refresh response missing access_token: #{inspect(response)}")
      {:error, :invalid_refresh_response}
    else
      expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

      # Update database
      attrs = %{
        access_token: access_token,
        refresh_token: refresh_token,
        expires_at: expires_at
      }

      case update_token(state.id, attrs) do
        {:ok, token} ->
          Logger.info("Claude OAuth token refreshed, new expiry: #{expires_at}")
          {:ok, token_to_state(token)}

        {:error, reason} ->
          Logger.error("Failed to persist refreshed token: #{inspect(reason)}")
          # Return the new token anyway - it's valid even if we couldn't persist
          new_state = %{
            state
            | access_token: access_token,
              refresh_token: refresh_token,
              expires_at: expires_at
          }

          {:ok, new_state}
      end
    end
  end

  defp upsert_token(attrs) do
    # For now, we only support a single global token (user_id: nil)
    # When multi-user support is added, this will accept a user_id parameter
    case Repo.one(ClaudeToken.global_token_query()) do
      nil ->
        %ClaudeToken{}
        |> ClaudeToken.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> ClaudeToken.changeset(attrs)
        |> Repo.update()
    end
  end

  defp update_token(id, attrs) do
    case Repo.get(ClaudeToken, id) do
      nil ->
        {:error, :token_not_found}

      token ->
        token
        |> ClaudeToken.changeset(attrs)
        |> Repo.update()
    end
  end

  defp redact_token(nil), do: nil

  defp redact_token(token) when byte_size(token) > 20 do
    prefix = String.slice(token, 0, 15)
    "#{prefix}...REDACTED"
  end

  defp redact_token(token), do: "#{String.slice(token, 0, 5)}...REDACTED"
end
