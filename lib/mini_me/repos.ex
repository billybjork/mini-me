defmodule MiniMe.Repos do
  @moduledoc """
  Context for managing GitHub repositories.

  Repos are first-class entities that can be associated with tasks.
  Clone status is derived at runtime from sprite filesystem queries.
  """

  import Ecto.Query
  alias MiniMe.Repo, as: DBRepo
  alias MiniMe.Repos.Repo

  @doc """
  Get a repo by ID.
  """
  def get_repo(id), do: DBRepo.get(Repo, id)

  @doc """
  Get a repo by ID, raising if not found.
  """
  def get_repo!(id), do: DBRepo.get!(Repo, id)

  @doc """
  Get a repo by GitHub URL.
  """
  def get_repo_by_url(url), do: DBRepo.get_by(Repo, github_url: url)

  @doc """
  Get a repo by GitHub name (e.g., "owner/repo").
  """
  def get_repo_by_name(name), do: DBRepo.get_by(Repo, github_name: name)

  @doc """
  List all repos, ordered by most recently used.
  """
  def list_repos do
    Repo
    |> order_by([r], desc_nulls_last: r.last_used_at, desc: r.inserted_at)
    |> DBRepo.all()
  end

  @doc """
  Create a new repo.
  """
  def create_repo(attrs) do
    %Repo{}
    |> Repo.changeset(attrs)
    |> DBRepo.insert()
  end

  @doc """
  Find or create a repo by GitHub URL.
  Returns the repo record, creating it if it doesn't exist.
  """
  def find_or_create_repo(github_url, github_name) do
    case get_repo_by_url(github_url) do
      nil ->
        create_repo(%{github_url: github_url, github_name: github_name})

      repo ->
        {:ok, repo}
    end
  end

  @doc """
  Mark a repo as recently used.
  """
  def touch_repo(repo) do
    repo
    |> Repo.touch_changeset()
    |> DBRepo.update()
  end

  @doc """
  Delete a repo.
  """
  def delete_repo(repo), do: DBRepo.delete(repo)

  @doc """
  Get working directory for a repo on a sprite.

  Repos are cloned to /home/sprite/repos/{owner}/{repo} to keep them
  organized and separate from other task artifacts.
  """
  def working_dir(repo), do: "/home/sprite/repos/#{repo.github_name}"
end
