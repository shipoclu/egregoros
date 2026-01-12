defmodule EgregorosWeb.Plugs.UploadsHostRestrictionTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Egregoros.RuntimeConfig
  alias EgregorosWeb.Plugs.Uploads

  defp temp_dir do
    Path.join(["tmp", "test_uploads_host_restriction", Ecto.UUID.generate()])
  end

  test "serves uploads only on the uploads host when uploads_base_url is configured" do
    base_dir = temp_dir()
    uploads_dir = Path.join(base_dir, "uploads")
    avatar_path = Path.join([uploads_dir, "avatars", "1", "host-restriction-test.jpg"])

    try do
      RuntimeConfig.with(
        %{uploads_dir: uploads_dir, uploads_base_url: "https://i.example.com"},
        fn ->
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
        end
      )
    after
      File.rm_rf!(base_dir)
    end
  end
end
