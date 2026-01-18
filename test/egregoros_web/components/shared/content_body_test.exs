defmodule EgregorosWeb.Components.Shared.ContentBodyTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EgregorosWeb.Components.Shared.ContentBody

  test "renders E2EE payload metadata and unlock UI when egregoros:e2ee_dm is present" do
    html =
      render_component(&ContentBody.content_body/1, %{
        id: "post-1",
        current_user: %{ap_id: "http://localhost:4000/users/alice"},
        object: %{
          local: true,
          data: %{
            "content" => "Secret",
            "egregoros:e2ee_dm" => %{"ciphertext" => "abc"}
          }
        }
      })

    assert html =~ ~s(phx-hook="E2EEDMMessage")
    assert html =~ ~s(data-role="e2ee-dm-body")
    assert html =~ ~s(data-role="e2ee-dm-unlock")
    assert html =~ ~s(data-current-user-ap-id="http://localhost:4000/users/alice")
    assert html =~ ~s(data-e2ee-dm=)
  end

  test "collapses long remote HTML content behind a show-more toggle" do
    long_text = String.duplicate("a", 600)

    html =
      render_component(&ContentBody.content_body/1, %{
        id: "post-1",
        current_user: nil,
        object: %{
          local: false,
          data: %{
            "content" => "<p>#{long_text}</p>"
          }
        }
      })

    assert html =~ ~s(data-role="post-content-toggle")
    assert html =~ ~s(id="post-content-post-1")
    assert html =~ ~s(max-h-64)
    assert html =~ ~s(overflow-hidden)
  end
end
