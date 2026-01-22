defmodule MiniMe.Auth.ClaudeToken do
  @moduledoc """
  Stores Claude OAuth credentials for API authentication.

  ## Why Store Tokens in Database?

  Claude's OAuth access tokens expire after ~1 hour. Rather than requiring manual
  token regeneration, we store both the access token and refresh token. The
  ClaudeTokenManager uses the refresh token to automatically obtain new access
  tokens before they expire.

  ## Fields

  - `access_token`: Short-lived token passed to Claude Code (sk-ant-oat01-...)
  - `refresh_token`: Long-lived token used to get new access tokens (sk-ant-ort01-...)
  - `expires_at`: When the access token expires (UTC)
  - `scopes`: OAuth scopes granted (e.g., ["user:inference"])
  - `subscription_type`: "max", "pro", etc.
  - `user_id`: Reserved for future multi-user support (currently nil for global token)

  ## Security Note

  Tokens are stored in the database. Ensure your database is properly secured
  and consider encryption at rest in production environments.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "claude_tokens" do
    # User association - nil means global/system token
    # Future: belongs_to :user, MiniMe.Accounts.User
    field :user_id, :integer

    # OAuth tokens
    field :access_token, :string
    field :refresh_token, :string
    field :expires_at, :utc_datetime

    # Token metadata
    field :scopes, {:array, :string}, default: []
    field :subscription_type, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields [:access_token, :refresh_token, :expires_at]
  @optional_fields [:user_id, :scopes, :subscription_type]

  def changeset(token, attrs) do
    token
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_token_format(:access_token)
    |> validate_token_format(:refresh_token)
    |> unique_constraint(:user_id)
  end

  @doc """
  Query for the global token (user_id is nil).

  Used when operating in single-user mode before multi-user support is added.
  """
  def global_token_query do
    from(t in __MODULE__, where: is_nil(t.user_id))
  end

  # Validate token looks like an Anthropic OAuth token
  defp validate_token_format(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      cond do
        # Access tokens start with sk-ant-oat
        field == :access_token and not String.starts_with?(value, "sk-ant-") ->
          [{field, "must be a valid Anthropic OAuth access token"}]

        # Refresh tokens start with sk-ant-ort
        field == :refresh_token and not String.starts_with?(value, "sk-ant-") ->
          [{field, "must be a valid Anthropic OAuth refresh token"}]

        true ->
          []
      end
    end)
  end
end
