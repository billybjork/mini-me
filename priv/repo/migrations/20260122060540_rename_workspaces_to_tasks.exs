defmodule MiniMe.Repo.Migrations.RenameWorkspacesToTasks do
  use Ecto.Migration

  def change do
    # Rename the main table
    rename table(:workspaces), to: table(:tasks)

    # Rename foreign key columns in related tables
    rename table(:messages), :workspace_id, to: :task_id
    rename table(:execution_sessions), :workspace_id, to: :task_id
  end
end
