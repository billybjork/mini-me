defmodule MiniMeWeb.HomeLive do
  @moduledoc """
  Home page LiveView - displays task list and repo selector.
  """
  use MiniMeWeb, :live_view

  alias MiniMe.GitHub
  alias MiniMe.Sandbox.{Allocator, Client}
  alias MiniMe.{Tasks, Repos}
  alias Phoenix.LiveView.JS

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
      |> assign(:repo_form, to_form(%{"repo" => nil}))
      |> assign(:deleting, nil)
      |> assign(:current_tab, "tasks")
      |> assign(:sprites, [])

    # Load data asynchronously
    if connected?(socket) do
      send(self(), :load_github_repos)
      send(self(), :load_sprite_status)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "tasks"
    tab = if tab in ["tasks", "environments"], do: tab, else: "tasks"

    socket = assign(socket, current_tab: tab)

    # Load sprites when navigating to environments tab
    if tab == "environments" and connected?(socket) do
      send(self(), :load_sprites)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_github_repos, socket) do
    # Do blocking work in a separate process so UI stays responsive
    liveview_pid = self()

    Task.start(fn ->
      result = GitHub.list_repos()
      send(liveview_pid, {:github_repos_result, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:github_repos_result, {:ok, repos}}, socket) do
    {:noreply, assign(socket, github_repos: repos, loading: false)}
  end

  def handle_info({:github_repos_result, {:error, reason}}, socket) do
    {:noreply, assign(socket, error: reason, loading: false)}
  end

  def handle_info(:load_sprite_status, socket) do
    # Schedule next poll immediately so timing stays consistent
    Process.send_after(self(), :load_sprite_status, @status_poll_interval)

    # Do blocking work in a separate process so UI stays responsive
    liveview_pid = self()
    include_sprites = socket.assigns.current_tab == "environments"

    Task.start(fn ->
      sprite_name = Allocator.default_sprite_name()

      sprite_status =
        case Client.get_sprite(sprite_name) do
          {:ok, sprite} -> sprite["status"]
          _ -> nil
        end

      tasks = Tasks.list_tasks(preload_repo: true)

      sprites = if include_sprites, do: fetch_sprites(), else: nil

      send(liveview_pid, {:status_poll_result, sprite_status, tasks, sprites})
    end)

    {:noreply, socket}
  end

  def handle_info({:status_poll_result, sprite_status, tasks, sprites}, socket) do
    tasks_map = Map.new(tasks, &{&1.id, &1})

    socket =
      socket
      |> assign(:sprite_status, sprite_status)
      |> assign(:tasks_map, tasks_map)
      |> stream(:tasks, tasks, reset: true)

    socket = if sprites, do: assign(socket, sprites: sprites), else: socket

    {:noreply, socket}
  end

  def handle_info(:load_sprites, socket) do
    # Do blocking work in a separate process so UI stays responsive
    liveview_pid = self()

    Task.start(fn ->
      sprites =
        case Client.list_sprites() do
          {:ok, sprites} -> sprites
          _ -> []
        end

      send(liveview_pid, {:sprites_result, sprites})
    end)

    {:noreply, socket}
  end

  def handle_info({:sprites_result, sprites}, socket) do
    {:noreply, assign(socket, sprites: sprites)}
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
  def handle_event("start_session", %{"repo" => repo_json}, socket) when is_binary(repo_json) do
    case Jason.decode(repo_json) do
      {:ok, %{"url" => url, "name" => name}} ->
        # Find or create the repo, then create a task for it
        with {:ok, repo} <- Repos.find_or_create_repo(url, name),
             {:ok, task} <- Tasks.create_task_for_repo(repo) do
          # Pre-warm the sprite in background
          task_with_repo = %{task | repo: repo}
          Allocator.allocate(task_with_repo, prewarm: true)

          {:noreply, push_navigate(socket, to: ~p"/tasks/#{task.id}")}
        else
          {:error, changeset} ->
            {:noreply,
             put_flash(socket, :error, "Failed to create task: #{inspect(changeset.errors)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Please select a repository")}
    end
  end

  def handle_event("start_session", _params, socket) do
    {:noreply, put_flash(socket, :error, "Please select a repository")}
  end

  def handle_event("new_task", _params, socket) do
    # Create a task without a repo
    case Tasks.create_task() do
      {:ok, task} ->
        {:noreply, push_navigate(socket, to: ~p"/tasks/#{task.id}")}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to create task: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("open_task", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/tasks/#{id}")}
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

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?tab=#{tab}")}
  end

  def handle_event("hibernate_sprite", %{"name" => name}, socket) do
    # Optimistic update for sprites list
    sprites = update_sprite_status(socket.assigns.sprites, name, "suspending")

    # Also update header indicator if this is the default sprite
    sprite_status =
      if name == Allocator.default_sprite_name() do
        "suspending"
      else
        socket.assigns.sprite_status
      end

    socket = assign(socket, sprites: sprites, sprite_status: sprite_status)

    # Suspend in background
    Task.start(fn ->
      Client.exec(name, "pkill -f 'claude --print' || true", timeout: 5_000)
      Client.suspend_sprite(name)
    end)

    {:noreply, socket}
  end

  def handle_event("delete_sprite", %{"name" => name}, socket) do
    # Optimistic update - remove from list
    sprites = Enum.reject(socket.assigns.sprites, &(&1["name"] == name))

    # Also update header indicator if this is the default sprite
    sprite_status =
      if name == Allocator.default_sprite_name() do
        nil
      else
        socket.assigns.sprite_status
      end

    socket = assign(socket, sprites: sprites, sprite_status: sprite_status)

    # Delete in background
    Task.start(fn -> Client.delete_sprite(name) end)

    {:noreply, socket}
  end

  defp fetch_sprites do
    case Client.list_sprites() do
      {:ok, sprites} -> sprites
      _ -> []
    end
  end

  defp update_sprite_status(sprites, name, new_status) do
    Enum.map(sprites, fn sprite ->
      if sprite["name"] == name do
        Map.put(sprite, "status", new_status)
      else
        sprite
      end
    end)
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
        <div class="max-w-4xl mx-auto px-4 py-8 safe-bottom">
          <div class="flex items-center justify-between mb-6">
            <h1 class="text-3xl font-bold">Mini Me</h1>
            <.sprite_indicator status={@sprite_status} />
          </div>
          
    <!-- Tab Navigation -->
          <div class="flex gap-1 mb-6 border-b border-gray-700">
            <button
              id="tab-tasks"
              phx-click={switch_tab_js("tasks")}
              class={[
                "px-4 py-3 touch-target tap-highlight font-medium transition-colors border-b-2 -mb-px",
                if(@current_tab == "tasks",
                  do: "border-blue-500 text-blue-400",
                  else: "border-transparent text-gray-400 hover:text-gray-200"
                )
              ]}
            >
              Tasks
            </button>
            <button
              id="tab-environments"
              phx-click={switch_tab_js("environments")}
              class={[
                "px-4 py-3 touch-target tap-highlight font-medium transition-colors border-b-2 -mb-px",
                if(@current_tab == "environments",
                  do: "border-blue-500 text-blue-400",
                  else: "border-transparent text-gray-400 hover:text-gray-200"
                )
              ]}
            >
              Environments
            </button>
          </div>
          
    <!-- Tasks Tab -->
          <div id="panel-tasks" class={if(@current_tab != "tasks", do: "hidden")}>
            <!-- New Task Button -->
            <div class="mb-8">
              <button
                phx-click="new_task"
                phx-disable-with="Creating..."
                class="w-full py-3 px-4 tap-highlight bg-blue-600 hover:bg-blue-700 disabled:bg-gray-600 rounded-lg font-semibold transition-colors"
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
                    phx-disable-with="Opening..."
                    class="flex-1 text-left p-4 tap-highlight bg-gray-800 rounded-lg hover:bg-gray-700 active:bg-gray-600 disabled:bg-gray-700 transition-colors"
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
                      "p-3 touch-target flex items-center justify-center tap-highlight rounded-lg transition-colors",
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

              <.form
                :if={!@loading && @error == nil}
                for={@repo_form}
                phx-submit="start_session"
                class="space-y-4"
                id="repo-selector-form"
              >
                <div class="grid gap-2 max-h-96 overflow-y-auto">
                  <label
                    :for={repo <- @github_repos}
                    class="text-left p-4 tap-highlight active:bg-gray-600 rounded-lg transition-colors border-2 cursor-pointer bg-gray-800 border-transparent hover:bg-gray-700 has-[:checked]:bg-blue-900 has-[:checked]:border-blue-500"
                  >
                    <input
                      type="radio"
                      name="repo"
                      value={Jason.encode!(%{url: repo.url, name: repo.full_name})}
                      class="sr-only"
                    />
                    <div class="font-medium">{repo.full_name}</div>
                    <div :if={repo.description} class="text-sm text-gray-400 truncate">
                      {repo.description}
                    </div>
                    <div class="text-xs text-gray-500 mt-1">
                      {if repo.private, do: "Private", else: "Public"}
                    </div>
                  </label>
                </div>

                <button
                  type="submit"
                  phx-disable-with="Starting..."
                  class="w-full py-3 px-4 tap-highlight bg-green-600 hover:bg-green-700 disabled:bg-gray-600 rounded-lg font-semibold transition-colors"
                >
                  Start with Selected Repository
                </button>
              </.form>
            </div>
          </div>
          
    <!-- Environments Tab -->
          <div id="panel-environments" class={if(@current_tab != "environments", do: "hidden")}>
            <h2 class="text-xl font-semibold mb-4">Environments</h2>

            <div :if={@sprites == []} class="text-gray-400 py-8 text-center">
              No environments found. Environments are created automatically when you start a task.
            </div>

            <div class="space-y-2">
              <div
                :for={sprite <- @sprites}
                class="p-4 bg-gray-800 rounded-lg flex items-center justify-between"
              >
                <div>
                  <div class="font-medium">{sprite["name"]}</div>
                  <.sprite_status_badge status={sprite["status"]} />
                </div>
                <div class="flex gap-2">
                  <button
                    :if={sprite["status"] in ["running", "warm"]}
                    phx-click="hibernate_sprite"
                    phx-value-name={sprite["name"]}
                    class="px-4 py-2.5 touch-target tap-highlight bg-blue-600 hover:bg-blue-700 rounded text-sm font-medium transition-colors"
                  >
                    Hibernate
                  </button>
                  <button
                    phx-click="delete_sprite"
                    phx-value-name={sprite["name"]}
                    data-confirm="Delete this environment? All data will be lost."
                    class="px-4 py-2.5 touch-target tap-highlight bg-gray-700 hover:bg-red-600 text-gray-300 hover:text-white rounded text-sm font-medium transition-colors"
                  >
                    Delete
                  </button>
                </div>
              </div>
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

  # JS commands for instant tab switching (visual updates before server responds)
  defp switch_tab_js(tab) do
    other_tab = if tab == "tasks", do: "environments", else: "tasks"

    JS.hide(to: "#panel-#{other_tab}")
    |> JS.show(to: "#panel-#{tab}")
    |> JS.remove_class("border-blue-500 text-blue-400",
      to: "#tab-#{other_tab}"
    )
    |> JS.add_class("border-transparent text-gray-400",
      to: "#tab-#{other_tab}"
    )
    |> JS.remove_class("border-transparent text-gray-400",
      to: "#tab-#{tab}"
    )
    |> JS.add_class("border-blue-500 text-blue-400",
      to: "#tab-#{tab}"
    )
    |> JS.push("switch_tab", value: %{tab: tab})
  end

  # Sprite status indicator (for the shared sprite)
  defp sprite_indicator(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-1 rounded text-xs font-medium",
      sprite_status_classes(@status)
    ]}>
      <span class={["w-2 h-2 rounded-full", sprite_dot_classes(@status)]}></span>
      {sprite_status_text(@status)}
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

  defp sprite_status_text("running"), do: "Environment running"
  defp sprite_status_text("warm"), do: "Environment warm"
  defp sprite_status_text("suspending"), do: "Suspending..."
  defp sprite_status_text("cold"), do: "Environment sleeping"
  defp sprite_status_text(nil), do: "No environment"
  defp sprite_status_text(status), do: status

  # Sprite status badge (for sprites list)
  defp sprite_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs font-medium mt-1",
      sprite_status_classes(@status)
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full", sprite_dot_classes(@status)]}></span>
      {sprite_badge_text(@status)}
    </span>
    """
  end

  defp sprite_badge_text("running"), do: "Running"
  defp sprite_badge_text("warm"), do: "Warm"
  defp sprite_badge_text("suspending"), do: "Suspending..."
  defp sprite_badge_text("cold"), do: "Hibernated"
  defp sprite_badge_text(nil), do: "Unknown"
  defp sprite_badge_text(status), do: status

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
