defmodule Egregoros.Signature.HTTPStrictTest do
  use Egregoros.DataCase, async: false

  alias Egregoros.Keys
  alias Egregoros.Signature.HTTP
  alias Egregoros.Users

  setup do
    previous = Application.get_env(:egregoros, :signature_strict, false)

    on_exit(fn ->
      Application.put_env(:egregoros, :signature_strict, previous)
    end)

    :ok
  end

  defp create_remote_user(attrs) when is_map(attrs) do
    unique = Ecto.UUID.generate() |> String.replace("-", "")
    ap_id = "https://remote.example/users/alice-#{unique}"

    Users.create_user(
      Map.merge(
        %{
          nickname: "alice_#{unique}",
          ap_id: ap_id,
          inbox: ap_id <> "/inbox",
          outbox: ap_id <> "/outbox",
          local: false
        },
        attrs
      )
    )
  end

  test "strict mode rejects POST signatures missing recommended headers" do
    Application.put_env(:egregoros, :signature_strict, true)

    {public_key, private_key} = Keys.generate_rsa_keypair()

    {:ok, user} =
      create_remote_user(%{
        public_key: public_key,
        private_key: private_key
      })

    body = Jason.encode!(%{"id" => "https://remote.example/activities/1", "type" => "Like"})
    url = "https://local.example/users/frank/inbox"

    {:ok, signed} = HTTP.sign_request(user, "post", url, body, ["(request-target)", "date"])

    conn =
      Plug.Test.conn(:post, "/users/frank/inbox", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> Plug.Conn.put_req_header("date", signed.date)
      |> Plug.Conn.put_req_header("signature", signed.signature)

    conn = %{conn | host: "local.example", scheme: :https, port: 443}

    assert {:error, :missing_required_signature_headers} = HTTP.verify_request(conn)
  end

  test "strict mode accepts POST signatures including recommended headers" do
    Application.put_env(:egregoros, :signature_strict, true)

    {public_key, private_key} = Keys.generate_rsa_keypair()

    {:ok, user} =
      create_remote_user(%{
        public_key: public_key,
        private_key: private_key
      })

    body = Jason.encode!(%{"id" => "https://remote.example/activities/2", "type" => "Like"})
    url = "https://local.example/users/frank/inbox"

    {:ok, signed} = HTTP.sign_request(user, "post", url, body)

    conn =
      Plug.Test.conn(:post, "/users/frank/inbox", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> Plug.Conn.put_req_header("date", signed.date)
      |> Plug.Conn.put_req_header("digest", signed.digest)
      |> Plug.Conn.put_req_header("content-length", signed.content_length)
      |> Plug.Conn.put_req_header("signature", signed.signature)

    conn = %{conn | host: "local.example", scheme: :https, port: 443}

    assert {:ok, signer_ap_id} = HTTP.verify_request(conn)
    assert signer_ap_id == user.ap_id
  end
end
