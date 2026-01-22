defmodule MiniMeWeb.HomeLive do
  @moduledoc """
  Home page LiveView - displays repo selector and recent tasks.
  """
  use MiniMeWeb, :live_view

  alias MiniMe.GitHub
  alias MiniMe.Sandbox.Client
  alias MiniMe.Tasks

  # Poll for sprite status updates every 5 seconds
  @status_poll_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    tasks = Tasks.list_tasks()
    tasks_map = Map.new(tasks, &{&1.id, &1})

    socket =
      socket
      |> assign(:repos, [])
      |> stream(:tasks, tasks)
      |> assign(:tasks_map, tasks_map)
      |> assign(:sprite_statuses, %{})
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:selected_repo, nil)
      |> assign(:deleting, nil)

    # Load repos and sprite statuses asynchronously
    if connected?(socket) do
      send(self(), :load_repos)
      send(self(), :load_sprite_statuses)
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

  def handle_info(:load_sprite_statuses, socket) do
    # Fetch real-time sprite statuses from the API
    sprite_statuses =
      case Client.list_sprites() do
        {:ok, sprites} when is_list(sprites) ->
          Map.new(sprites, fn sprite ->
            {sprite["name"], sprite["status"]}
          end)

        _ ->
          socket.assigns.sprite_statuses
      end

    # Also refresh tasks in case they changed
    tasks = Tasks.list_tasks()
    tasks_map = Map.new(tasks, &{&1.id, &1})

    # Schedule next poll
    Process.send_after(self(), :load_sprite_statuses, @status_poll_interval)

    socket =
      socket
      |> assign(:sprite_statuses, sprite_statuses)
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
        case Tasks.find_or_create_task(url, name) do
          {:ok, task} ->
            {:noreply, push_navigate(socket, to: ~p"/session/#{task.id}")}

          {:error, changeset} ->
            {:noreply,
             put_flash(socket, :error, "Failed to create task: #{inspect(changeset.errors)}")}
        end
    end
  end

  def handle_event("open_task", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/session/#{id}")}
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    task_id = String.to_integer(id)

    # Guard against double-clicks - ignore if already deleting this task
    if socket.assigns.deleting == task_id do
      {:noreply, socket}
    else
      socket.assigns.tasks_map
      |> Map.get(task_id)
      |> do_delete_task(socket)
    end
  end

  def handle_event("sleep_sprite", %{"id" => id}, socket) do
    socket.assigns.tasks_map
    |> Map.get(String.to_integer(id))
    |> do_sleep_sprite(socket)
  end

  defp do_delete_task(nil, socket), do: {:noreply, socket}

  defp do_delete_task(task, socket) do
    socket = assign(socket, deleting: task.id)
    liveview_pid = self()

    # Delete sprite first, then task (in background)
    Task.start(fn ->
      Client.delete_sprite(task.sprite_name)
      # Use Repo.delete with allow_stale to handle race conditions
      Tasks.delete_task(task)
      send(liveview_pid, {:task_deleted, task.id})
    end)

    {:noreply, socket}
  end

  defp do_sleep_sprite(nil, socket), do: {:noreply, socket}

  defp do_sleep_sprite(task, socket) do
    sprite_status = Map.get(socket.assigns.sprite_statuses, task.sprite_name)

    # Optimistic update - show transitional state
    sprite_statuses = Map.put(socket.assigns.sprite_statuses, task.sprite_name, "suspending")
    socket = assign(socket, :sprite_statuses, sprite_statuses)

    # Only kill Claude if sprite is actually running (avoid waking it up)
    maybe_kill_claude(task, sprite_status)

    # Suspend in background - the regular poll will refresh the status
    Task.start(fn -> Client.suspend_sprite(task.sprite_name) end)

    {:noreply, socket}
  end

  defp maybe_kill_claude(task, "running") do
    Task.start(fn ->
      Client.exec(task.sprite_name, "pkill -f 'claude --print' || true", timeout: 5_000)
    end)
  end

  defp maybe_kill_claude(_task, _status), do: :ok

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.full_screen flash={@flash}>
      <div class="min-h-screen bg-gray-900 text-white">
        <div class="max-w-4xl mx-auto px-4 py-8">
          <h1 class="text-3xl font-bold mb-8">Mini Me</h1>

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
                    <div class="font-medium">{task.github_repo_name}</div>
                    <.sprite_status_badge
                      sprite_name={task.sprite_name}
                      sprite_statuses={@sprite_statuses}
                    />
                  </div>
                  <div class="text-sm text-gray-400 mt-1">
                    <.task_status_text
                      status={task.status}
                      sprite_status={Map.get(@sprite_statuses, task.sprite_name)}
                    />
                  </div>
                </button>
                <button
                  :if={Map.get(@sprite_statuses, task.sprite_name) in ["running"]}
                  phx-click="sleep_sprite"
                  phx-value-id={task.id}
                  phx-disable-with="..."
                  class="p-3 rounded-lg transition-colors bg-gray-800 hover:bg-blue-900 text-gray-400 hover:text-blue-400"
                  title="Put sprite to sleep (stops charges)"
                >
                  ⏸
                </button>
                <button
                  phx-click="delete_task"
                  phx-value-id={task.id}
                  phx-disable-with="..."
                  data-confirm="Delete this task and its sprite? This cannot be undone."
                  class={[
                    "p-3 rounded-lg transition-colors",
                    if(@deleting == task.id,
                      do: "bg-gray-700 text-gray-500 cursor-wait",
                      else: "bg-gray-800 hover:bg-red-900 text-gray-400 hover:text-red-400"
                    )
                  ]}
                  disabled={@deleting == task.id}
                  title="Delete task and sprite"
                >
                  {if @deleting == task.id, do: "...", else: "×"}
                </button>
              </div>
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
    </Layouts.full_screen>
    """
  end

  # Component for sprite status badge (running vs hibernating)
  defp sprite_status_badge(assigns) do
    sprite_status = Map.get(assigns.sprite_statuses, assigns.sprite_name)

    assigns = assign(assigns, :sprite_status, sprite_status)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium",
      sprite_status_classes(@sprite_status)
    ]}>
      <span class={[
        "w-2 h-2 rounded-full",
        sprite_dot_classes(@sprite_status)
      ]}>
      </span>
      {sprite_status_text(@sprite_status)}
    </span>
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

  # Show raw API status values for clarity
  defp sprite_status_text("running"), do: "running"
  defp sprite_status_text("warm"), do: "warm"
  defp sprite_status_text("suspending"), do: "suspending..."
  defp sprite_status_text("cold"), do: "cold"
  defp sprite_status_text(nil), do: "?"
  defp sprite_status_text(status), do: status

  # Component for task status text
  attr :status, :string, required: true
  attr :sprite_status, :string, default: nil

  defp task_status_text(assigns) do
    # Detect stale status: sprite is cold but task is in an intermediate state
    is_stale = assigns.sprite_status == "cold" and assigns.status in ["creating", "cloning"]

    assigns = assign(assigns, :is_stale, is_stale)

    ~H"""
    <span :if={@is_stale} class="text-orange-400">
      Setup interrupted - will resume on open
    </span>
    <span :if={!@is_stale} class={task_status_classes(@status)}>
      {task_status_label(@status)}
    </span>
    """
  end

  defp task_status_classes("ready"), do: "text-green-400"
  defp task_status_classes("error"), do: "text-red-400"
  defp task_status_classes("pending"), do: "text-gray-500"
  defp task_status_classes(_), do: "text-yellow-400"

  defp task_status_label("ready"), do: "Ready"
  defp task_status_label("pending"), do: "Pending"
  defp task_status_label("creating"), do: "Creating sprite..."
  defp task_status_label("cloning"), do: "Cloning repo..."
  defp task_status_label("error"), do: "Error"
  defp task_status_label(status), do: status
end
