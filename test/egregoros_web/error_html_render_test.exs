defmodule EgregorosWeb.ErrorHTMLRenderTest do
  use ExUnit.Case, async: true

  alias EgregorosWeb.ErrorHTML

  test "render/2 returns the status message for the template" do
    assert ErrorHTML.render("404.html", %{}) == "Not Found"
    assert ErrorHTML.render("500.html", %{}) == "Internal Server Error"
  end
end
