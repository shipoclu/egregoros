defmodule Egregoros.Signature.HTTPTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Signature.HTTP
  alias Egregoros.HTTPDate
  alias Egregoros.Keys
  alias Egregoros.Users

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

  describe "verify_request/1" do
    test "returns missing_signature when no signature header is present" do
      conn = Plug.Test.conn(:post, "/users/frank/inbox", "")

      assert {:error, :missing_signature} = HTTP.verify_request(conn)
    end

    test "returns invalid_signature when keyId does not include an actor ap_id" do
      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", "")
        |> Plug.Conn.put_req_header(
          "signature",
          "Signature keyId=\"#main-key\",headers=\"(request-target) date\",signature=\"AA==\""
        )

      assert {:error, :invalid_signature} = HTTP.verify_request(conn)
    end

    test "returns invalid_signature when the signature param is not base64" do
      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", "")
        |> Plug.Conn.put_req_header(
          "signature",
          "Signature keyId=\"https://remote.example/users/alice#main-key\",signature=\"not-base64\""
        )

      assert {:error, :invalid_signature} = HTTP.verify_request(conn)
    end

    test "returns missing_date when the signature headers param omits date" do
      {public_key, _private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: nil
        })

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", "")
        |> Plug.Conn.put_req_header(
          "signature",
          "Signature keyId=\"#{user.ap_id}#main-key\",headers=\"(request-target)\",signature=\"AA==\""
        )

      assert {:error, :missing_date} = HTTP.verify_request(conn)
    end

    test "returns invalid_date for malformed date headers" do
      {public_key, _private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: nil
        })

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", "")
        |> Plug.Conn.put_req_header("date", "definitely-not-a-date")
        |> Plug.Conn.put_req_header(
          "signature",
          "Signature keyId=\"#{user.ap_id}#main-key\",headers=\"(request-target) date\",signature=\"AA==\""
        )

      assert {:error, :invalid_date} = HTTP.verify_request(conn)
    end

    test "returns date_skew when the date header is too old" do
      {public_key, _private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: nil
        })

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", "")
        |> Plug.Conn.put_req_header("date", "Sun, 06 Nov 1994 08:49:37 GMT")
        |> Plug.Conn.put_req_header(
          "signature",
          "Signature keyId=\"#{user.ap_id}#main-key\",headers=\"(request-target) date\",signature=\"AA==\""
        )

      assert {:error, :date_skew} = HTTP.verify_request(conn)
    end

    test "returns invalid_method when request method is not supported" do
      {public_key, _private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: nil
        })

      date = HTTPDate.format_rfc1123(DateTime.utc_now())

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", "")
        |> Map.put(:method, "TRACE")
        |> Plug.Conn.put_req_header("date", date)
        |> Plug.Conn.put_req_header(
          "signature",
          "Signature keyId=\"#{user.ap_id}#main-key\",headers=\"(request-target) date\",signature=\"AA==\""
        )

      assert {:error, :invalid_method} = HTTP.verify_request(conn)
    end

    test "verifies requests using x-forwarded host/proto/port" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = ""
      url = "https://forwarded.example:8443/users/frank/inbox"

      {:ok, signed} = HTTP.sign_request(user, "post", url, body)

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("digest", signed.digest)
        |> Plug.Conn.put_req_header("content-length", signed.content_length)
        |> Plug.Conn.put_req_header("signature", signed.signature)
        |> Plug.Conn.put_req_header("x-forwarded-host", "forwarded.example, other.example")
        |> Plug.Conn.put_req_header("x-forwarded-port", "8443")
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")

      conn = %{conn | host: "internal.local", scheme: :http, port: 4000}

      assert {:ok, signer_ap_id} = HTTP.verify_request(conn)
      assert signer_ap_id == user.ap_id
    end

    test "verifies requests when the request contains a query string" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = ""
      url = "https://local.example/users/frank/inbox"

      {:ok, signed} = HTTP.sign_request(user, "post", url, body)

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox?foo=bar", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("digest", signed.digest)
        |> Plug.Conn.put_req_header("content-length", signed.content_length)
        |> Plug.Conn.put_req_header("signature", signed.signature)

      conn = %{conn | host: "local.example", scheme: :https, port: 443}

      assert {:ok, signer_ap_id} = HTTP.verify_request(conn)
      assert signer_ap_id == user.ap_id
    end

    test "returns invalid_signature for mismatched request targets" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = ""
      url = "https://local.example/users/frank/inbox"

      {:ok, signed} = HTTP.sign_request(user, "post", url, body)

      conn =
        Plug.Test.conn(:post, "/users/frank/other", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("digest", signed.digest)
        |> Plug.Conn.put_req_header("content-length", signed.content_length)
        |> Plug.Conn.put_req_header("signature", signed.signature)

      conn = %{conn | host: "local.example", scheme: :https, port: 443}

      assert {:error, :invalid_signature} = HTTP.verify_request(conn)
    end

    test "ignores invalid signature param fragments without crashing" do
      {public_key, _private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: nil
        })

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", "")
        |> Plug.Conn.put_req_header("date", HTTPDate.format_rfc1123(DateTime.utc_now()))
        |> Plug.Conn.put_req_header(
          "signature",
          "Signature foo,keyId=\"#{user.ap_id}#main-key\",headers=\"(request-target) date\",signature=\"AA==\""
        )

      assert {:error, :invalid_signature} = HTTP.verify_request(conn)
    end
  end

  test "sign_request generates a verifiable signature" do
    {public_key, private_key} = Keys.generate_rsa_keypair()

    {:ok, user} =
      create_remote_user(%{
        public_key: public_key,
        private_key: private_key
      })

    body = Jason.encode!(%{"id" => "https://remote.example/objects/1", "type" => "Note"})

    {:ok, signed} =
      HTTP.sign_request(user, "post", "https://local.example/users/frank/inbox", body)

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

  test "sign_request returns Signature params and Authorization value" do
    {:ok, user} = Users.create_local_user("alice")

    {:ok, signed} =
      HTTP.sign_request(user, "get", "https://remote.example/objects/1", "", [
        "(request-target)",
        "host",
        "date"
      ])

    assert is_binary(signed.signature)
    refute String.starts_with?(signed.signature, "Signature ")
    assert signed.authorization == "Signature " <> signed.signature
  end
end
