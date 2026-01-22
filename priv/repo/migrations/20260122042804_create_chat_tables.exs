defmodule MiniMe.Repo.Migrations.CreateChatTables do
  use Ecto.Migration

  def change do
    create table(:execution_sessions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :session_type, :string, null: false, default: "claude_code"
      add :status, :string, null: false, default: "started"
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :metadata, :map, default: %{}

      timestamps()
    end

    create index(:execution_sessions, [:workspace_id])
    create index(:execution_sessions, [:workspace_id, :status])

    create table(:messages) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :execution_session_id, references(:execution_sessions, on_delete: :nilify_all)
      add :type, :string, null: false
      add :content, :text
      add :tool_data, :map

      timestamps()
    end

    create index(:messages, [:workspace_id])
    create index(:messages, [:execution_session_id])
    create index(:messages, [:workspace_id, :inserted_at])
  end
end
