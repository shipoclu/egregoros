defmodule EgregorosWeb.Live.UploadsTest do
  use ExUnit.Case, async: true

  alias EgregorosWeb.Live.Uploads

  test "cancel_all/2 returns the socket unchanged when the upload is missing" do
    socket = %Phoenix.LiveView.Socket{assigns: %{uploads: %{}}}
    assert Uploads.cancel_all(socket, :reply_media) == socket
  end
end
