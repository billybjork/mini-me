defmodule MiniMe.GitHub do
  @moduledoc """
  GitHub API client using HTTP requests.
  Uses GITHUB_TOKEN for authentication.
  """

  @base_url "https://api.github.com"

  @doc """
  List user's repositories via GitHub API.
  Returns `{:ok, repos}` or `{:error, reason}`.
  """
  def list_repos(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    case get_token() do
      nil ->
        {:error, "GITHUB_TOKEN not configured"}

      token ->
        # Fetch repos sorted by most recently pushed
        url = "#{@base_url}/user/repos"

        params = [
          sort: "pushed",
          direction: "desc",
          per_page: limit,
          type: "all"
        ]

        case Req.get(url, headers: auth_headers(token), params: params) do
          {:ok, %{status: 200, body: repos}} ->
            {:ok, format_repos(repos)}

          {:ok, %{status: status, body: body}} ->
            {:error, "GitHub API error (#{status}): #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Request failed: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Check if GitHub token is configured and valid.
  """
  def check_auth do
    case get_token() do
      nil ->
        {:error, "GITHUB_TOKEN not configured"}

      token ->
        url = "#{@base_url}/user"

        case Req.get(url, headers: auth_headers(token)) do
          {:ok, %{status: 200, body: user}} ->
            {:ok, "Authenticated as #{user["login"]}"}

          {:ok, %{status: status, body: body}} ->
            {:error, "GitHub API error (#{status}): #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Request failed: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Get repository details.
  """
  def get_repo(name_with_owner) do
    case get_token() do
      nil ->
        {:error, "GITHUB_TOKEN not configured"}

      token ->
        url = "#{@base_url}/repos/#{name_with_owner}"

        case Req.get(url, headers: auth_headers(token)) do
          {:ok, %{status: 200, body: repo}} ->
            {:ok, format_repo(repo)}

          {:ok, %{status: 404}} ->
            {:error, "Repository not found: #{name_with_owner}"}

          {:ok, %{status: status, body: body}} ->
            {:error, "GitHub API error (#{status}): #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Request failed: #{inspect(reason)}"}
        end
    end
  end

  # Private Functions

  defp get_token do
    Application.get_env(:mini_me, :github_token)
  end

  defp auth_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  defp format_repos(repos) do
    Enum.map(repos, &format_repo/1)
  end

  defp format_repo(repo) do
    %{
      name: repo["name"],
      full_name: repo["full_name"] || repo["nameWithOwner"],
      url: repo["html_url"] || repo["url"],
      description: repo["description"],
      private: repo["private"] || repo["isPrivate"],
      pushed_at: repo["pushed_at"] || repo["pushedAt"]
    }
  end
end
