defmodule TipsWeb.PageController do
  use TipsWeb, :controller

  def home(conn, _params) do
    render(conn, :home, page_title: "Home")
  end
end
