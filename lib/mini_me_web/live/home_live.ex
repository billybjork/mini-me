defmodule MiniMeWeb.HomeLive do
  @moduledoc """
  Home page LiveView - displays repo selector and recent workspaces.
  """
  use MiniMeWeb, :live_view

  alias MiniMe.GitHub
  alias MiniMe.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:repos, [])
      |> assign(:workspaces, Workspaces.list_workspaces())
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:selected_repo, nil)

    # Load repos asynchronously
    if connected?(socket) do
      send(self(), :load_repos)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_repos, socket) do
    case GitHub.list_repos() do
      {:ok, repos} ->
        {:noreply, assign(socket, repos: repos, loading: false)}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason, loading: false)}
    end
  end

  @impl true
  def handle_event("select_repo", %{"url" => url, "name" => name}, socket) do
    {:noreply, assign(socket, selected_repo: %{url: url, name: name})}
  end

  def handle_event("start_session", _params, socket) do
    case socket.assigns.selected_repo do
      nil ->
        {:noreply, put_flash(socket, :error, "Please select a repository")}

      %{url: url, name: name} ->
        case Workspaces.find_or_create_workspace(url, name) do
          {:ok, workspace} ->
            {:noreply, push_navigate(socket, to: ~p"/session/#{workspace.id}")}

          {:error, changeset} ->
            {:noreply,
             put_flash(socket, :error, "Failed to create workspace: #{inspect(changeset.errors)}")}
        end
    end
  end

  def handle_event("open_workspace", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/session/#{id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-white">
      <div class="max-w-4xl mx-auto px-4 py-8">
        <h1 class="text-3xl font-bold mb-8">Mini Me</h1>
        
    <!-- Recent Workspaces -->
        <div :if={length(@workspaces) > 0} class="mb-8">
          <h2 class="text-xl font-semibold mb-4">Recent Workspaces</h2>
          <div class="space-y-2">
            <button
              :for={workspace <- @workspaces}
              phx-click="open_workspace"
              phx-value-id={workspace.id}
              class="w-full text-left p-4 bg-gray-800 rounded-lg hover:bg-gray-700 transition-colors"
            >
              <div class="font-medium">{workspace.github_repo_name}</div>
              <div class="text-sm text-gray-400">
                Status: {workspace.status} | Sprite: {workspace.sprite_name}
              </div>
            </button>
          </div>
        </div>
        
    <!-- Repository Selector -->
        <div class="mb-8">
          <h2 class="text-xl font-semibold mb-4">Start New Session</h2>

          <div :if={@loading} class="text-gray-400">
            Loading repositories...
          </div>

          <div :if={@error} class="text-red-400 mb-4">
            Error loading repos: {@error}
            <div class="text-sm mt-2">
              Make sure gh CLI is installed and authenticated: <code>gh auth login</code>
            </div>
          </div>

          <div :if={!@loading && @error == nil} class="space-y-4">
            <div class="grid gap-2 max-h-96 overflow-y-auto">
              <button
                :for={repo <- @repos}
                phx-click="select_repo"
                phx-value-url={repo.url}
                phx-value-name={repo.full_name}
                class={[
                  "text-left p-4 rounded-lg transition-colors border-2",
                  if(@selected_repo && @selected_repo.url == repo.url,
                    do: "bg-blue-900 border-blue-500",
                    else: "bg-gray-800 border-transparent hover:bg-gray-700"
                  )
                ]}
              >
                <div class="font-medium">{repo.full_name}</div>
                <div :if={repo.description} class="text-sm text-gray-400 truncate">
                  {repo.description}
                </div>
                <div class="text-xs text-gray-500 mt-1">
                  {if repo.private, do: "Private", else: "Public"}
                </div>
              </button>
            </div>

            <button
              :if={@selected_repo}
              phx-click="start_session"
              class="w-full py-3 px-4 bg-blue-600 hover:bg-blue-700 rounded-lg font-semibold transition-colors"
            >
              Start Session with {@selected_repo.name}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
