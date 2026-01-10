defmodule EgregorosWeb.MediaViewerTest do
  use EgregorosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EgregorosWeb.MediaViewer

  test "close button is layered above media content" do
    html =
      render_component(&MediaViewer.media_viewer/1, %{
        viewer: %{
          items: [
            %{href: "/uploads/media/1/clip.mp4", media_type: "video/mp4", description: "Clip"}
          ],
          index: 0
        },
        open: true
      })

    assert html =~
             ~r/<button(?=[^>]*data-role="media-viewer-close")(?=[^>]*\bz-20\b)[^>]*>/
  end

  test "renders audio items with CORS-enabled audio tag" do
    html =
      render_component(&MediaViewer.media_viewer/1, %{
        viewer: %{
          items: [
            %{href: "/uploads/media/1/sound.mp3", media_type: "audio/mpeg", description: "Sound"}
          ],
          index: 0
        },
        open: true
      })

    assert html =~ "<audio"
    assert html =~ ~s(crossorigin="anonymous")
  end
end
