defmodule MiniMe.Repos.Repo do
  @moduledoc """
  Schema representing a GitHub repository.

  Repos are first-class entities that can be associated with tasks.
  Clone status is derived at runtime from the sprite's filesystem.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "repos" do
    field :github_url, :string
    field :github_name, :string
    field :default_branch, :string, default: "main"
    field :last_used_at, :utc_datetime
    field :locked_at, :utc_datetime

    has_many :tasks, MiniMe.Tasks.Task
    belongs_to :locked_by_task, MiniMe.Tasks.Task

    timestamps(type: :utc_datetime)
  end

  def changeset(repo, attrs) do
    repo
    |> cast(attrs, [:github_url, :github_name, :default_branch, :last_used_at])
    |> validate_required([:github_url, :github_name])
    |> unique_constraint(:github_url)
    |> unique_constraint(:github_name)
  end

  def touch_changeset(repo) do
    changeset(repo, %{last_used_at: DateTime.utc_now()})
  end
end
