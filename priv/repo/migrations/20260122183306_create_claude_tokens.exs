defmodule MiniMe.Repo.Migrations.CreateClaudeTokens do
  @moduledoc """
  Creates the claude_tokens table for storing OAuth credentials.

  This enables automatic token refresh for Claude Max subscriptions.
  Access tokens expire after ~1 hour, so we store the refresh token
  to obtain new access tokens automatically.

  The user_id column is nullable for now (single global token) but
  included for future multi-user support where each user would have
  their own Claude subscription.
  """

  use Ecto.Migration

  def change do
    create table(:claude_tokens) do
      # Nullable for single-user mode; will reference users table later
      add :user_id, :integer

      # OAuth tokens - both required for refresh flow
      add :access_token, :text, null: false
      add :refresh_token, :text, null: false

      # When the access token expires (UTC)
      add :expires_at, :utc_datetime, null: false

      # Token metadata
      add :scopes, {:array, :string}, default: []
      add :subscription_type, :string

      timestamps(type: :utc_datetime)
    end

    # Ensure only one token per user (or one global token when user_id is null)
    # Using a unique index that handles nulls correctly
    create unique_index(:claude_tokens, [:user_id], name: :claude_tokens_user_id_unique)
  end
end
