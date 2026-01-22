defmodule MiniMe.Repo.Migrations.AddRepoLocks do
  use Ecto.Migration

  def change do
    alter table(:repos) do
      add :locked_by_task_id, references(:tasks, on_delete: :nilify_all)
      add :locked_at, :utc_datetime
    end

    create index(:repos, [:locked_by_task_id])
  end
end
