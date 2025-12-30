defmodule EgregorosWeb.Plugs.StaticAssetsTest do
  use ExUnit.Case, async: true

  alias EgregorosWeb.Plugs.StaticAssets

  defp priv_static_dir do
    :egregoros
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("static")
  end

  test "skips /uploads paths so Uploads plug can serve them" do
    static_root = priv_static_dir()
    uploads_dir = Path.join([static_root, "uploads", "avatars", "1"])
    file_path = Path.join(uploads_dir, "static-assets-test.jpg")

    File.mkdir_p!(uploads_dir)
    File.write!(file_path, "ok")

    on_exit(fn -> File.rm_rf!(uploads_dir) end)

    opts =
      StaticAssets.init(
        at: "/",
        from: :egregoros,
        gzip: false,
        only: EgregorosWeb.static_paths(),
        raise_on_missing_only: true
      )

    conn =
      Plug.Test.conn(:get, "/uploads/avatars/1/static-assets-test.jpg")
      |> StaticAssets.call(opts)

    refute conn.halted
    assert conn.status == nil
  end

  test "serves regular static assets" do
    static_root = priv_static_dir()
    images_dir = Path.join([static_root, "images"])
    file_path = Path.join(images_dir, "static-assets-test.txt")

    File.mkdir_p!(images_dir)
    File.write!(file_path, "ok")

    on_exit(fn -> File.rm_rf!(file_path) end)

    opts =
      StaticAssets.init(
        at: "/",
        from: :egregoros,
        gzip: false,
        only: EgregorosWeb.static_paths(),
        raise_on_missing_only: true
      )

    conn =
      Plug.Test.conn(:get, "/images/static-assets-test.txt")
      |> StaticAssets.call(opts)

    assert conn.status == 200
    assert conn.halted
  end
end
