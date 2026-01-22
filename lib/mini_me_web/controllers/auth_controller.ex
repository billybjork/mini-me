defmodule MiniMeWeb.AuthController do
  use MiniMeWeb, :controller

  alias MiniMeWeb.Plugs.Auth

  def callback(conn, %{"password" => password}) do
    if Auth.valid_password?(password) do
      conn
      |> Auth.authenticate()
      |> redirect(to: ~p"/")
    else
      conn
      |> put_flash(:error, "Invalid password")
      |> redirect(to: ~p"/login")
    end
  end

  def logout(conn, _params) do
    conn
    |> Auth.logout()
    |> redirect(to: ~p"/login")
  end
end
