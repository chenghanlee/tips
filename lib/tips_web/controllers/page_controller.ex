defmodule TipsWeb.PageController do
  use TipsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
