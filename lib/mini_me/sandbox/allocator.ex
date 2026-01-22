defmodule MiniMe.Sandbox.Allocator do
  @moduledoc """
  Manages sprite allocation and repo locking.

  For MVP, we use a single default sprite. Tasks are allocated to this sprite
  and repos are cloned as needed. Repo locking ensures only one active task
  uses a repo at a time on a given sprite.

  ## Responsibilities

  - Allocate sprites for tasks (currently just returns the default sprite)
  - Track repo locks (which task is using which repo)
  - Clone repos when needed
  - Configure git credentials
  - Pre-warm sprites on task creation
  """
  use GenServer
  require Logger

  alias MiniMe.Sandbox.Client
  alias MiniMe.Repos

  @default_sprite_name "mini-me-default"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Allocate a sprite for a task. Returns the sprite name and working directory.

  If the task has a repo, ensures:
  1. The repo is not locked by another active task
  2. The repo is cloned on the sprite
  3. Git credentials are configured

  Options:
  - `:prewarm` - If true, starts allocation in background (default: false)
  """
  def allocate(task, opts \\ []) do
    if Keyword.get(opts, :prewarm, false) do
      GenServer.cast(__MODULE__, {:prewarm, task})
      :ok
    else
      GenServer.call(__MODULE__, {:allocate, task}, 120_000)
    end
  end

  @doc """
  Release a sprite allocation for a task.
  """
  def release(task) do
    GenServer.cast(__MODULE__, {:release, task})
  end

  @doc """
  Check if a repo is locked by a task.
  """
  def repo_locked?(repo_id) do
    GenServer.call(__MODULE__, {:repo_locked?, repo_id})
  end

  @doc """
  Get the default sprite name.
  """
  def default_sprite_name, do: @default_sprite_name

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      # Map of repo_id => task_id (which task has the lock)
      repo_locks: %{},
      # Map of task_id => %{sprite_name, repo_id, allocated_at}
      allocations: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:allocate, task}, _from, state) do
    repo_id = task.repo_id

    case check_and_acquire_lock(state, task.id, repo_id) do
      {:ok, state} ->
        # Ensure sprite exists and repo is cloned
        case setup_sprite_for_task(task) do
          {:ok, sprite_name, working_dir} ->
            allocation = %{
              sprite_name: sprite_name,
              repo_id: repo_id,
              allocated_at: DateTime.utc_now()
            }

            state = put_in(state.allocations[task.id], allocation)
            {:reply, {:ok, %{sprite_name: sprite_name, working_dir: working_dir}}, state}

          {:error, reason} ->
            # Release lock on failure
            state = release_lock(state, task.id, repo_id)
            {:reply, {:error, reason}, state}
        end

      {:error, :repo_locked, locking_task_id} ->
        {:reply, {:error, {:repo_locked, locking_task_id}}, state}
    end
  end

  def handle_call({:repo_locked?, repo_id}, _from, state) do
    locked = Map.has_key?(state.repo_locks, repo_id)
    {:reply, locked, state}
  end

  @impl true
  def handle_cast({:prewarm, task}, state) do
    # Pre-warm in background, don't block
    spawn(fn ->
      case setup_sprite_for_task(task) do
        {:ok, _sprite_name, _working_dir} ->
          Logger.info("Pre-warmed sprite for task #{task.id}")

        {:error, reason} ->
          Logger.warning("Failed to pre-warm sprite for task #{task.id}: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  def handle_cast({:release, task}, state) do
    case Map.get(state.allocations, task.id) do
      nil ->
        {:noreply, state}

      %{repo_id: repo_id} ->
        state =
          state
          |> release_lock(task.id, repo_id)
          |> Map.update!(:allocations, &Map.delete(&1, task.id))

        {:noreply, state}
    end
  end

  # Private Functions

  defp check_and_acquire_lock(state, _task_id, nil) do
    # No repo, no lock needed
    {:ok, state}
  end

  defp check_and_acquire_lock(state, task_id, repo_id) do
    case Map.get(state.repo_locks, repo_id) do
      nil ->
        # Acquire lock
        state = put_in(state.repo_locks[repo_id], task_id)
        {:ok, state}

      ^task_id ->
        # Already have the lock
        {:ok, state}

      other_task_id ->
        # Locked by another task
        {:error, :repo_locked, other_task_id}
    end
  end

  defp release_lock(state, _task_id, nil), do: state

  defp release_lock(state, task_id, repo_id) do
    case Map.get(state.repo_locks, repo_id) do
      ^task_id ->
        Map.update!(state, :repo_locks, &Map.delete(&1, repo_id))

      _ ->
        state
    end
  end

  defp setup_sprite_for_task(task) do
    sprite_name = @default_sprite_name
    # Only use repo if it's loaded (avoid NotLoaded struct)
    repo = if task.repo_id && Ecto.assoc_loaded?(task.repo), do: task.repo, else: nil

    with {:ok, _sprite} <- ensure_sprite_exists(sprite_name),
         :ok <- configure_git_credentials(sprite_name),
         {:ok, working_dir} <- ensure_repo_cloned(sprite_name, repo) do
      {:ok, sprite_name, working_dir}
    end
  end

  defp ensure_sprite_exists(sprite_name) do
    case Client.create_sprite(sprite_name) do
      {:ok, sprite} ->
        {:ok, sprite}

      {:error, reason} ->
        Logger.error("Failed to create/get sprite #{sprite_name}: #{inspect(reason)}")
        {:error, {:sprite_creation_failed, reason}}
    end
  end

  defp configure_git_credentials(sprite_name) do
    case Application.get_env(:mini_me, :github_token) do
      nil ->
        Logger.warning("No GitHub token configured, git operations may fail")
        :ok

      token ->
        if git_already_configured?(sprite_name) do
          Logger.debug("Git credentials already configured on #{sprite_name}")
          :ok
        else
          do_configure_git_credentials(sprite_name, token)
        end
    end
  end

  defp git_already_configured?(sprite_name) do
    case Client.exec(sprite_name, "git config --global user.email", timeout: 10_000) do
      {:ok, %{"exit_code" => 0, "output" => output}} when output != "" -> true
      _ -> false
    end
  end

  defp do_configure_git_credentials(sprite_name, token) do
    credential_cmd = """
    git config --global credential.helper store && \
    echo "https://oauth2:#{token}@github.com" > ~/.git-credentials && \
    git config --global user.email "mini-me@example.com" && \
    git config --global user.name "Mini Me"
    """

    case Client.exec(sprite_name, credential_cmd, timeout: 30_000) do
      {:ok, %{"exit_code" => 0}} ->
        :ok

      {:ok, %{"exit_code" => _, "output" => output}} ->
        handle_git_config_error(sprite_name, output)

      {:error, reason} ->
        {:error, {:git_config_failed, reason}}
    end
  end

  defp handle_git_config_error(sprite_name, output) do
    # If the error is a lock conflict, another process is configuring git
    # concurrently - wait briefly and check if config succeeded
    if String.contains?(output, "could not lock config file") do
      Logger.debug("Git config locked, waiting for concurrent configuration")
      Process.sleep(500)

      if git_already_configured?(sprite_name),
        do: :ok,
        else: {:error, {:git_config_failed, output}}
    else
      {:error, {:git_config_failed, output}}
    end
  end

  defp ensure_repo_cloned(_sprite_name, nil) do
    # No repo, just use home directory
    {:ok, "/home/sprite"}
  end

  defp ensure_repo_cloned(sprite_name, repo) do
    working_dir = Repos.working_dir(repo)

    # Check if a repo is already cloned at the working directory
    case Client.exec(sprite_name, "test -d #{working_dir}/.git") do
      {:ok, %{"exit_code" => 0}} ->
        # A repo exists - verify it's the correct one by checking remote URL
        case verify_repo_remote(sprite_name, working_dir, repo.github_url) do
          :ok ->
            Logger.info("Correct repo already cloned at #{working_dir}, pulling latest")
            pull_repo(sprite_name, working_dir)

          :mismatch ->
            # Wrong repo cloned - need to re-clone the correct one
            Logger.warning("Wrong repo at #{working_dir}, re-cloning #{repo.github_name}")

            clone_repo(sprite_name, repo.github_url, working_dir)
        end

      _ ->
        # Need to clone
        Logger.info("Cloning #{repo.github_name} to #{working_dir}")
        clone_repo(sprite_name, repo.github_url, working_dir)
    end
  end

  defp verify_repo_remote(sprite_name, working_dir, expected_url) do
    # Get the current remote URL and compare with expected
    cmd = "cd #{working_dir} && git remote get-url origin"

    case Client.exec(sprite_name, cmd, timeout: 10_000) do
      {:ok, %{"exit_code" => 0, "output" => output}} ->
        actual_url = String.trim(output)

        # Normalize URLs for comparison (handle .git suffix and trailing slashes)
        if normalize_git_url(actual_url) == normalize_git_url(expected_url) do
          :ok
        else
          Logger.debug("Repo mismatch: expected #{expected_url}, got #{actual_url}")
          :mismatch
        end

      _ ->
        # Can't determine remote, treat as mismatch to be safe
        :mismatch
    end
  end

  defp normalize_git_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
    |> String.downcase()
  end

  defp clone_repo(sprite_name, github_url, working_dir) do
    # Ensure parent directory exists
    parent_dir = Path.dirname(working_dir)
    Client.exec(sprite_name, "mkdir -p #{parent_dir}", timeout: 10_000)

    # Remove existing directory if it exists (e.g., from interrupted clone)
    Client.exec(sprite_name, "rm -rf #{working_dir}", timeout: 30_000)

    clone_cmd = "git clone #{github_url} #{working_dir}"

    case Client.exec(sprite_name, clone_cmd, timeout: 300_000) do
      {:ok, %{"exit_code" => 0}} ->
        {:ok, working_dir}

      {:ok, %{"exit_code" => _, "output" => output}} ->
        {:error, {:clone_failed, output}}

      {:error, reason} ->
        {:error, {:clone_failed, reason}}
    end
  end

  defp pull_repo(sprite_name, working_dir) do
    case Client.exec(sprite_name, "cd #{working_dir} && git pull", timeout: 120_000) do
      {:ok, %{"exit_code" => 0}} ->
        {:ok, working_dir}

      {:ok, %{"exit_code" => _, "output" => output}} ->
        # Pull failed, but repo exists - continue anyway
        Logger.warning("Git pull failed: #{output}")
        {:ok, working_dir}

      {:error, reason} ->
        Logger.warning("Git pull error: #{inspect(reason)}")
        {:ok, working_dir}
    end
  end
end
