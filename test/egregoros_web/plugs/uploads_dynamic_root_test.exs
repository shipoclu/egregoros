defmodule EgregorosWeb.Plugs.UploadsDynamicRootTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias EgregorosWeb.Plugs.Uploads

  defp temp_dir do
    Path.join(["tmp", "test_uploads_dynamic_root", Ecto.UUID.generate()])
  end

  test "serves from the current uploads_dir even if options were initialized earlier" do
    base_dir = temp_dir()
    dir_a = Path.join(base_dir, "a")
    dir_b = Path.join(base_dir, "b")
    file_path = Path.join([dir_b, "avatars", "1", "dynamic-root-test.jpg"])
    original = Application.get_env(:egregoros, :uploads_dir)

    try do
      Application.put_env(:egregoros, :uploads_dir, dir_a)
      opts = Uploads.init([])

      Application.put_env(:egregoros, :uploads_dir, dir_b)
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "ok")

      conn =
        conn(:get, "/uploads/avatars/1/dynamic-root-test.jpg")
        |> init_test_session(%{})
        |> Uploads.call(opts)

      assert conn.status == 200
      assert conn.halted
    after
      if is_binary(original) do
        Application.put_env(:egregoros, :uploads_dir, original)
      else
        Application.delete_env(:egregoros, :uploads_dir)
      end

      File.rm_rf!(base_dir)
    end
  end
end

