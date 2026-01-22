defmodule MiniMeWeb.LoginLive do
  @moduledoc """
  Simple password login page.
  """
  use MiniMeWeb, :live_view

  alias MiniMeWeb.Plugs.Auth

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :error, nil)}
  end

  @impl true
  def handle_event("login", %{"password" => password}, socket) do
    if Auth.valid_password?(password) do
      {:noreply, redirect(socket, to: ~p"/auth/callback?password=#{password}")}
    else
      {:noreply, assign(socket, :error, "Invalid password")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 flex items-center justify-center">
      <div class="bg-gray-800 p-8 rounded-lg shadow-lg w-full max-w-md">
        <h1 class="text-2xl font-bold text-white mb-6 text-center">Mini Me</h1>

        <form phx-submit="login" class="space-y-4">
          <div :if={@error} class="text-red-400 text-sm text-center">
            {@error}
          </div>

          <div>
            <label class="block text-gray-300 text-sm mb-2">Password</label>
            <input
              type="password"
              name="password"
              placeholder="Enter password"
              class="w-full px-4 py-2 bg-gray-700 border border-gray-600 rounded-lg text-white focus:outline-none focus:border-blue-500"
              autofocus
            />
          </div>

          <button
            type="submit"
            class="w-full py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-semibold transition-colors"
          >
            Login
          </button>
        </form>
      </div>
    </div>
    """
  end
end
