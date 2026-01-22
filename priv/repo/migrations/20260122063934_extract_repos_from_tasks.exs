defmodule MiniMe.Repo.Migrations.ExtractReposFromTasks do
  use Ecto.Migration

  def up do
    # 1. Create repos table
    create table(:repos) do
      add :github_url, :string, null: false
      add :github_name, :string, null: false
      add :default_branch, :string, default: "main"
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:repos, [:github_url])
    create unique_index(:repos, [:github_name])

    # 2. Migrate existing task data to repos
    execute """
    INSERT INTO repos (github_url, github_name, last_used_at, inserted_at, updated_at)
    SELECT DISTINCT github_repo_url, github_repo_name, updated_at, inserted_at, updated_at
    FROM tasks
    WHERE github_repo_url IS NOT NULL
    ON CONFLICT (github_url) DO NOTHING
    """

    # 3. Add repo_id to tasks
    alter table(:tasks) do
      add :repo_id, references(:repos, on_delete: :nilify_all)
      add :title, :string
    end

    # 4. Populate repo_id from existing data
    execute """
    UPDATE tasks
    SET repo_id = repos.id
    FROM repos
    WHERE tasks.github_repo_url = repos.github_url
    """

    # 5. Remove old columns from tasks
    alter table(:tasks) do
      remove :github_repo_url
      remove :github_repo_name
      remove :sprite_name
      remove :working_dir
    end

    # 6. Update tasks status - convert old status values to new simpler ones
    # Old: pending, creating, cloning, ready, error
    # New: active, awaiting_input, idle (these are now derived, so just set to idle)
    execute """
    UPDATE tasks SET status = 'idle'
    """

    # 7. Add sprite_name to execution_sessions (tracks which sprite ran the execution)
    alter table(:execution_sessions) do
      add :sprite_name, :string
    end

    create index(:tasks, [:repo_id])
  end

  def down do
    # Reverse the migration

    alter table(:execution_sessions) do
      remove :sprite_name
    end

    alter table(:tasks) do
      add :github_repo_url, :string
      add :github_repo_name, :string
      add :sprite_name, :string
      add :working_dir, :string
    end

    # Restore data from repos
    execute """
    UPDATE tasks
    SET github_repo_url = repos.github_url,
        github_repo_name = repos.github_name
    FROM repos
    WHERE tasks.repo_id = repos.id
    """

    alter table(:tasks) do
      remove :repo_id
      remove :title
    end

    drop table(:repos)
  end
end
