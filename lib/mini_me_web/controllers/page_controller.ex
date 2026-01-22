defmodule MiniMeWeb.PageController do
  use MiniMeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
