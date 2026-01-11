defmodule EgregorosWeb.Plugs.UploadsHostRestrictionTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias EgregorosWeb.Plugs.Uploads

  defp temp_dir do
    Path.join(["tmp", "test_uploads_host_restriction", Ecto.UUID.generate()])
  end

  test "serves uploads only on the uploads host when uploads_base_url is configured" do
    base_dir = temp_dir()
    uploads_dir = Path.join(base_dir, "uploads")
    avatar_path = Path.join([uploads_dir, "avatars", "1", "host-restriction-test.jpg"])
    original_uploads_dir = Application.get_env(:egregoros, :uploads_dir)
    original_uploads_base_url = Application.get_env(:egregoros, :uploads_base_url)

    try do
      Application.put_env(:egregoros, :uploads_dir, uploads_dir)
      Application.put_env(:egregoros, :uploads_base_url, "https://i.example.com")

      File.mkdir_p!(Path.dirname(avatar_path))
      File.write!(avatar_path, "ok")

      opts = Uploads.init([])

      conn =
        conn(:get, "/uploads/avatars/1/host-restriction-test.jpg")
        |> Map.put(:host, "example.com")
        |> init_test_session(%{})
        |> Uploads.call(opts)

      assert conn.status == 404
      assert conn.halted

      conn =
        conn(:get, "/uploads/avatars/1/host-restriction-test.jpg")
        |> Map.put(:host, "i.example.com")
        |> init_test_session(%{})
        |> Uploads.call(opts)

      assert conn.status == 200
      assert conn.halted
    after
      restore_env(:uploads_dir, original_uploads_dir)
      restore_env(:uploads_base_url, original_uploads_base_url)
      File.rm_rf!(base_dir)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:egregoros, key)
  defp restore_env(key, value), do: Application.put_env(:egregoros, key, value)
end
