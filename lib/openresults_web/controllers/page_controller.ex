defmodule OpenResultsWeb.PageController do
  use OpenResultsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
