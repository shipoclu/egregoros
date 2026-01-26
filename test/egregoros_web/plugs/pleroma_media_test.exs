defmodule EgregorosWeb.Plugs.PleromaMediaTest do
  use EgregorosWeb.ConnCase, async: true

  alias Egregoros.RuntimeConfig

  test "serves configured legacy Pleroma /media/* uploads", %{conn: conn} do
    root =
      Path.join([
        System.tmp_dir!(),
        "pleroma-media-test-#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "abc"))
    File.write!(Path.join(root, "abc/file.txt"), "hello")

    RuntimeConfig.with(%{pleroma_media_dir: root}, fn ->
      conn = get(conn, "/media/abc/file.txt")
      assert conn.status == 200
      assert conn.resp_body == "hello"
    end)
  end

  test "returns 404 for missing /media/* uploads", %{conn: conn} do
    root =
      Path.join([
        System.tmp_dir!(),
        "pleroma-media-test-#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(root)

    RuntimeConfig.with(%{pleroma_media_dir: root}, fn ->
      conn = get(conn, "/media/does-not-exist.png")
      assert response(conn, 404)
    end)
  end
end
