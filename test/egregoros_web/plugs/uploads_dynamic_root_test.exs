defmodule EgregorosWeb.Plugs.UploadsDynamicRootTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Egregoros.RuntimeConfig
  alias EgregorosWeb.Plugs.Uploads

  defp temp_dir do
    Path.join(["tmp", "test_uploads_dynamic_root", Ecto.UUID.generate()])
  end

  test "serves from the current uploads_dir even if options were initialized earlier" do
    base_dir = temp_dir()
    dir_a = Path.join(base_dir, "a")
    dir_b = Path.join(base_dir, "b")
    file_path = Path.join([dir_b, "avatars", "1", "dynamic-root-test.jpg"])

    try do
      RuntimeConfig.with(%{uploads_dir: dir_a}, fn ->
        opts = Uploads.init([])

        RuntimeConfig.with(%{uploads_dir: dir_b}, fn ->
          File.mkdir_p!(Path.dirname(file_path))
          File.write!(file_path, "ok")

          conn =
            conn(:get, "/uploads/avatars/1/dynamic-root-test.jpg")
            |> init_test_session(%{})
            |> Uploads.call(opts)

          assert conn.status == 200
          assert conn.halted
        end)
      end)
    after
      File.rm_rf!(base_dir)
    end
  end
end
