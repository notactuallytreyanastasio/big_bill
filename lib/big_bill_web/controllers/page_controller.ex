defmodule BigBillWeb.PageController do
  use BigBillWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
