defmodule MiniMe.GitHub do
  @moduledoc """
  Wrapper for `gh` CLI commands.
  Assumes gh CLI is installed and authenticated.
  """

  @doc """
  List user's repositories via gh CLI.
  Returns `{:ok, repos}` or `{:error, reason}`.
  """
  def list_repos(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    args = [
      "repo",
      "list",
      "--json",
      "name,nameWithOwner,url,description,isPrivate,pushedAt",
      "--limit",
      to_string(limit)
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, repos} ->
            {:ok, format_repos(repos)}

          {:error, _} ->
            {:error, "Failed to parse gh output: #{output}"}
        end

      {error, _code} ->
        {:error, error}
    end
  end

  @doc """
  Check if gh CLI is installed and authenticated.
  """
  def check_auth do
    case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {error, _code} ->
        {:error, error}
    end
  end

  @doc """
  Get repository details.
  """
  def get_repo(name_with_owner) do
    args = [
      "repo",
      "view",
      name_with_owner,
      "--json",
      "name,nameWithOwner,url,description,isPrivate,defaultBranchRef"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, repo} -> {:ok, format_repo(repo)}
          {:error, _} -> {:error, "Failed to parse gh output"}
        end

      {error, _code} ->
        {:error, error}
    end
  end

  # Private Functions

  defp format_repos(repos) do
    Enum.map(repos, &format_repo/1)
  end

  defp format_repo(repo) do
    %{
      name: repo["name"],
      full_name: repo["nameWithOwner"],
      url: repo["url"],
      description: repo["description"],
      private: repo["isPrivate"],
      pushed_at: repo["pushedAt"]
    }
  end
end
