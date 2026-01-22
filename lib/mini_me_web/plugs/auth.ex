defmodule MiniMeWeb.Plugs.Auth do
  @moduledoc """
  Simple password-based authentication plug.
  Checks for authenticated session or redirects to login.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if authenticated?(conn) do
      conn
    else
      conn
      |> put_flash(:error, "Please log in to continue")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  @doc """
  Check if the current session is authenticated.
  """
  def authenticated?(conn) do
    get_session(conn, :authenticated) == true
  end

  @doc """
  Mark the session as authenticated.
  """
  def authenticate(conn) do
    put_session(conn, :authenticated, true)
  end

  @doc """
  Validate the provided password.
  """
  def valid_password?(password) do
    expected = Application.get_env(:mini_me, :auth_password, "dev")
    Plug.Crypto.secure_compare(password, expected)
  end

  @doc """
  Log out the current session.
  """
  def logout(conn) do
    delete_session(conn, :authenticated)
  end
end
