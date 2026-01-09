defmodule Egregoros.Security.UploadsSecurityHeadersTest do
  use ExUnit.Case, async: true

  @moduletag :security

  import Plug.Conn
  import Plug.Test

  alias EgregorosWeb.Plugs.Uploads

  test "uploads responses include secure browser headers (nosniff, xfo, xss-protection)" do
    filename = "security-headers-#{Ecto.UUID.generate()}.jpg"
    uploads_root = Uploads.uploads_root()
    file_path = Path.join([uploads_root, "avatars", "1", filename])

    try do
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "ok")

      opts = Uploads.init([])

      conn =
        conn(:get, "/uploads/avatars/1/#{filename}")
        |> init_test_session(%{})
        |> Uploads.call(opts)

      assert conn.status == 200

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") != []
      assert get_resp_header(conn, "x-xss-protection") != []
    after
      File.rm_rf!(Path.dirname(file_path))
    end
  end
end
