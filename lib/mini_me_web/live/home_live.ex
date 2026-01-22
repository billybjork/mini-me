defmodule MiniMeWeb.HomeLive do
  @moduledoc """
  Home page LiveView - displays task list and repo selector.
  """
  use MiniMeWeb, :live_view

  alias MiniMe.GitHub
  alias MiniMe.Sandbox.{Allocator, Client}
  alias MiniMe.{Tasks, Repos}

  # Poll for status updates every 5 seconds
  @status_poll_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    tasks = Tasks.list_tasks(preload_repo: true)
    tasks_map = Map.new(tasks, &{&1.id, &1})

    socket =
      socket
      |> assign(:github_repos, [])
      |> stream(:tasks, tasks)
      |> assign(:tasks_map, tasks_map)
      |> assign(:sprite_status, nil)
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:selected_repo, nil)
      |> assign(:deleting, nil)

    # Load data asynchronously
    if connected?(socket) do
      send(self(), :load_github_repos)
      send(self(), :load_sprite_status)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_github_repos, socket) do
    case GitHub.list_repos() do
      {:ok, repos} ->
        {:noreply, assign(socket, github_repos: repos, loading: false)}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason, loading: false)}
    end
  end

  def handle_info(:load_sprite_status, socket) do
    # Get status of the default sprite
    sprite_name = Allocator.default_sprite_name()

    sprite_status =
      case Client.get_sprite(sprite_name) do
        {:ok, sprite} -> sprite["status"]
        _ -> nil
      end

    # Refresh tasks
    tasks = Tasks.list_tasks(preload_repo: true)
    tasks_map = Map.new(tasks, &{&1.id, &1})

    # Schedule next poll
    Process.send_after(self(), :load_sprite_status, @status_poll_interval)

    socket =
      socket
      |> assign(:sprite_status, sprite_status)
      |> assign(:tasks_map, tasks_map)
      |> stream(:tasks, tasks, reset: true)

    {:noreply, socket}
  end

  def handle_info({:task_deleted, task_id}, socket) do
    case Map.get(socket.assigns.tasks_map, task_id) do
      nil ->
        {:noreply, assign(socket, deleting: nil)}

      task ->
        socket =
          socket
          |> stream_delete(:tasks, task)
          |> update(:tasks_map, &Map.delete(&1, task_id))
          |> assign(:deleting, nil)

        {:noreply, socket}
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
        # Find or create the repo, then create a task for it
        with {:ok, repo} <- Repos.find_or_create_repo(url, name),
             {:ok, task} <- Tasks.create_task_for_repo(repo) do
          # Pre-warm the sprite in background
          task_with_repo = %{task | repo: repo}
          Allocator.allocate(task_with_repo, prewarm: true)

          {:noreply, push_navigate(socket, to: ~p"/session/#{task.id}")}
        else
          {:error, changeset} ->
            {:noreply,
             put_flash(socket, :error, "Failed to create task: #{inspect(changeset.errors)}")}
        end
    end
  end

  def handle_event("new_task", _params, socket) do
    # Create a task without a repo
    case Tasks.create_task() do
      {:ok, task} ->
        {:noreply, push_navigate(socket, to: ~p"/session/#{task.id}")}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to create task: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("open_task", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/session/#{id}")}
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    task_id = String.to_integer(id)

    if socket.assigns.deleting == task_id do
      {:noreply, socket}
    else
      socket.assigns.tasks_map
      |> Map.get(task_id)
      |> do_delete_task(socket)
    end
  end

  def handle_event("sleep_sprite", _params, socket) do
    sprite_name = Allocator.default_sprite_name()

    # Optimistic update
    socket = assign(socket, :sprite_status, "suspending")

    # Kill Claude and suspend in background
    Task.start(fn ->
      Client.exec(sprite_name, "pkill -f 'claude --print' || true", timeout: 5_000)
      Client.suspend_sprite(sprite_name)
    end)

    {:noreply, socket}
  end

  defp do_delete_task(nil, socket), do: {:noreply, socket}

  defp do_delete_task(task, socket) do
    socket = assign(socket, deleting: task.id)
    liveview_pid = self()

    Task.start(fn ->
      Tasks.delete_task(task)
      send(liveview_pid, {:task_deleted, task.id})
    end)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.full_screen flash={@flash}>
      <div class="min-h-screen bg-gray-900 text-white">
        <div class="max-w-4xl mx-auto px-4 py-8">
          <div class="flex items-center justify-between mb-8">
            <h1 class="text-3xl font-bold">Mini Me</h1>
            <.sprite_indicator status={@sprite_status} />
          </div>

          <!-- New Task Button -->
          <div class="mb-8">
            <button
              phx-click="new_task"
              class="w-full py-3 px-4 bg-blue-600 hover:bg-blue-700 rounded-lg font-semibold transition-colors"
            >
              + New Task
            </button>
          </div>

          <!-- Recent Tasks -->
          <div :if={map_size(@tasks_map) > 0} class="mb-8">
            <h2 class="text-xl font-semibold mb-4">Recent Tasks</h2>
            <div class="space-y-2" id="tasks" phx-update="stream">
              <div
                :for={{dom_id, task} <- @streams.tasks}
                id={dom_id}
                class="flex items-center gap-2"
              >
                <button
                  phx-click="open_task"
                  phx-value-id={task.id}
                  class="flex-1 text-left p-4 bg-gray-800 rounded-lg hover:bg-gray-700 transition-colors"
                >
                  <div class="flex items-center justify-between">
                    <div class="font-medium">
                      {task_display_name(task)}
                    </div>
                    <.task_status_badge status={task.status} />
                  </div>
                  <div :if={task.repo} class="text-sm text-gray-500 mt-1">
                    {task.repo.github_name}
                  </div>
                </button>
                <button
                  phx-click="delete_task"
                  phx-value-id={task.id}
                  phx-disable-with="..."
                  data-confirm="Delete this task? This cannot be undone."
                  class={[
                    "p-3 rounded-lg transition-colors",
                    if(@deleting == task.id,
                      do: "bg-gray-700 text-gray-500 cursor-wait",
                      else: "bg-gray-800 hover:bg-red-900 text-gray-400 hover:text-red-400"
                    )
                  ]}
                  disabled={@deleting == task.id}
                  title="Delete task"
                >
                  {if @deleting == task.id, do: "...", else: "×"}
                </button>
              </div>
            </div>
          </div>

          <!-- Repository Selector -->
          <div class="mb-8">
            <h2 class="text-xl font-semibold mb-4">Start Task with Repository</h2>

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
                  :for={repo <- @github_repos}
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
                class="w-full py-3 px-4 bg-green-600 hover:bg-green-700 rounded-lg font-semibold transition-colors"
              >
                Start with {@selected_repo.name}
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.full_screen>
    """
  end

  # Display name for a task
  defp task_display_name(%{title: title}) when is_binary(title) and title != "", do: title
  defp task_display_name(%{repo: %{github_name: name}}) when is_binary(name), do: name
  defp task_display_name(%{id: id}), do: "Task ##{id}"

  # Sprite status indicator (for the shared sprite)
  defp sprite_indicator(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <button
        :if={@status == "running"}
        phx-click="sleep_sprite"
        class="text-sm px-3 py-1 bg-gray-800 hover:bg-blue-900 rounded text-gray-400 hover:text-blue-400 transition-colors"
        title="Put environment to sleep"
      >
        ⏸ Sleep
      </button>
      <span class={[
        "inline-flex items-center gap-1.5 px-2 py-1 rounded text-xs font-medium",
        sprite_status_classes(@status)
      ]}>
        <span class={["w-2 h-2 rounded-full", sprite_dot_classes(@status)]}></span>
        {sprite_status_text(@status)}
      </span>
    </div>
    """
  end

  defp sprite_status_classes("running"), do: "bg-green-900/50 text-green-400"
  defp sprite_status_classes("warm"), do: "bg-yellow-900/50 text-yellow-400"
  defp sprite_status_classes("suspending"), do: "bg-blue-900/50 text-blue-400"
  defp sprite_status_classes("cold"), do: "bg-gray-700 text-gray-400"
  defp sprite_status_classes(nil), do: "bg-gray-700 text-gray-500"
  defp sprite_status_classes(_), do: "bg-blue-900/50 text-blue-400"

  defp sprite_dot_classes("running"), do: "bg-green-400 animate-pulse"
  defp sprite_dot_classes("warm"), do: "bg-yellow-400 animate-pulse"
  defp sprite_dot_classes("suspending"), do: "bg-blue-400 animate-spin"
  defp sprite_dot_classes("cold"), do: "bg-gray-500"
  defp sprite_dot_classes(nil), do: "bg-gray-600"
  defp sprite_dot_classes(_), do: "bg-blue-400"

  defp sprite_status_text("running"), do: "Environment running"
  defp sprite_status_text("warm"), do: "Environment warm"
  defp sprite_status_text("suspending"), do: "Suspending..."
  defp sprite_status_text("cold"), do: "Environment sleeping"
  defp sprite_status_text(nil), do: "No environment"
  defp sprite_status_text(status), do: status

  # Task status badge
  defp task_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium",
      task_status_classes(@status)
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full", task_dot_classes(@status)]}></span>
      {task_status_label(@status)}
    </span>
    """
  end

  defp task_status_classes("active"), do: "bg-green-900/50 text-green-400"
  defp task_status_classes("awaiting_input"), do: "bg-yellow-900/50 text-yellow-400"
  defp task_status_classes("idle"), do: "bg-gray-700 text-gray-400"
  defp task_status_classes(_), do: "bg-gray-700 text-gray-500"

  defp task_dot_classes("active"), do: "bg-green-400 animate-pulse"
  defp task_dot_classes("awaiting_input"), do: "bg-yellow-400"
  defp task_dot_classes("idle"), do: "bg-gray-500"
  defp task_dot_classes(_), do: "bg-gray-600"

  defp task_status_label("active"), do: "Active"
  defp task_status_label("awaiting_input"), do: "Your turn"
  defp task_status_label("idle"), do: "Idle"
  defp task_status_label(status), do: status
end
