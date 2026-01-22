defmodule MiniMe.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add :github_repo_url, :string, null: false
      add :github_repo_name, :string, null: false
      add :sprite_name, :string, null: false
      add :working_dir, :string, default: "/home/sprite/repo"
      add :status, :string, default: "pending"
      add :error_message, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:sprite_name])
    create unique_index(:workspaces, [:github_repo_url])
  end
end
