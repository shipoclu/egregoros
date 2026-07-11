defmodule Egregoros.Signature.HTTPTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Signature.HTTP
  alias Egregoros.HTTPDate
  alias Egregoros.Keys
  alias Egregoros.MiniApps.ActorActivation
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.User
  alias Egregoros.Users

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :public_host_aliases, [] -> ["www.example.com", "local.example", "forwarded.example"]
      :trusted_proxies, [] -> ["10.0.0.0/8"]
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
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

    test "rejects a valid date-only POST signature by default" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = Jason.encode!(%{"id" => user.ap_id <> "/activities/weak", "type" => "Like"})
      url = "https://local.example/users/frank/inbox"

      {:ok, signed} = HTTP.sign_request(user, "post", url, body, ["date"])

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("signature", signed.signature)

      conn = %{conn | host: "local.example", scheme: :https, port: 443}

      assert {:error, :missing_required_signature_headers} = HTTP.verify_request(conn)
    end

    test "verifies signatures when digest uses a lowercase sha-256 prefix" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = Jason.encode!(%{"id" => "https://remote.example/activities/1", "type" => "Like"})
      date = HTTPDate.format_rfc1123(DateTime.utc_now())
      digest = "sha-256=" <> Base.encode64(:crypto.hash(:sha256, body))

      request_target = "post /users/frank/inbox"

      signature_string =
        Enum.join(
          [
            "(request-target): #{request_target}",
            "host: local.example",
            "date: #{date}",
            "digest: #{digest}",
            "content-type: application/activity+json"
          ],
          "\n"
        )

      [entry] = :public_key.pem_decode(private_key)
      decoded_private_key = :public_key.pem_entry_decode(entry)

      signature =
        :public_key.sign(signature_string, :sha256, decoded_private_key) |> Base.encode64()

      signature_header =
        "Signature " <>
          "keyId=\"#{user.ap_id}#main-key\"," <>
          "headers=\"(request-target) host date digest content-type\"," <>
          "signature=\"#{signature}\""

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", date)
        |> Plug.Conn.put_req_header("digest", digest)
        |> Plug.Conn.put_req_header("content-type", "application/activity+json")
        |> Plug.Conn.put_req_header("signature", signature_header)

      conn = %{conn | host: "local.example", scheme: :https, port: 443}

      assert {:ok, signer_ap_id} = HTTP.verify_request(conn)
      assert signer_ap_id == user.ap_id
    end

    test "verifies forwarded authority only from a trusted proxy" do
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
        |> Plug.Conn.put_req_header("x-forwarded-host", "forwarded.example")
        |> Plug.Conn.put_req_header("x-forwarded-port", "8443")
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")

      conn = %{
        conn
        | host: "internal.local",
          scheme: :http,
          port: 4000,
          remote_ip: {10, 0, 0, 2}
      }

      assert {:ok, signer_ap_id} = HTTP.verify_request(conn)
      assert signer_ap_id == user.ap_id
    end

    test "ignores spoofed forwarded authority from an untrusted peer" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = ""

      {:ok, signed} =
        HTTP.sign_request(
          user,
          "post",
          "https://forwarded.example:8443/users/frank/inbox",
          body
        )

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("digest", signed.digest)
        |> Plug.Conn.put_req_header("content-length", signed.content_length)
        |> Plug.Conn.put_req_header("signature", signed.signature)
        |> Plug.Conn.put_req_header("x-forwarded-host", "forwarded.example")
        |> Plug.Conn.put_req_header("x-forwarded-port", "8443")
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")

      conn = %{
        conn
        | host: "local.example",
          scheme: :https,
          port: 443,
          remote_ip: {203, 0, 113, 9}
      }

      assert {:error, :invalid_signature} = HTTP.verify_request(conn)
    end

    test "rejects a signed Host outside the configured public authorities" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = ""
      {:ok, signed} = HTTP.sign_request(user, "post", "https://evil.example/inbox", body)

      conn =
        Plug.Test.conn(:post, "/inbox", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("digest", signed.digest)
        |> Plug.Conn.put_req_header("content-length", signed.content_length)
        |> Plug.Conn.put_req_header("signature", signed.signature)

      conn = %{conn | host: "evil.example", scheme: :https, port: 443}

      assert {:error, :invalid_host} = HTTP.verify_request(conn)
    end

    test "verifies a declared mini-app actor from its pinned key without a network fetch" do
      origin = "https://app.example"
      actor = origin <> "/ap/actor"
      {public_key, private_key} = Keys.generate_rsa_keypair()

      assert {:ok, manifest} =
               Manifest.decode(
                 Jason.encode!(%{
                   "version" => "1",
                   "name" => "Pinned signer",
                   "homeUrl" => origin <> "/",
                   "activityPub" => %{
                     "actorUrl" => actor,
                     "publicNotes" => true,
                     "transactionalMentions" => false
                   },
                   "capabilities" => []
                 }),
                 origin <> "/.well-known/fediverse-miniapp.json"
               )

      assert {:ok, _declaration, :created} = Declarations.ensure(manifest)

      expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn ^actor, :actor ->
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/activity+json"}],
           body:
             Jason.encode!(%{
               "id" => actor,
               "type" => "Application",
               "inbox" => origin <> "/ap/inbox",
               "outbox" => origin <> "/ap/outbox",
               "followers" => origin <> "/ap/followers",
               "publicKey" => %{
                 "id" => actor <> "#main-key",
                 "owner" => actor,
                 "publicKeyPem" => public_key
               }
             })
         }}
      end)

      assert {:ok, _declaration} = ActorActivation.activate(origin)
      refute Users.get_by_ap_id(actor)

      expect(Egregoros.HTTP.Mock, :get, 0, fn _url, _headers ->
        flunk("signature verification must not refetch a declared mini-app actor")
      end)

      signer = %User{ap_id: actor, private_key: private_key}
      body = Jason.encode!(%{"id" => actor <> "/activities/1", "type" => "Create"})

      assert {:ok, signed} =
               HTTP.sign_request(
                 signer,
                 "post",
                 "https://local.example/users/frank/inbox",
                 body
               )

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("digest", signed.digest)
        |> Plug.Conn.put_req_header("content-length", signed.content_length)
        |> Plug.Conn.put_req_header("signature", signed.signature)

      conn = %{conn | host: "local.example", scheme: :https, port: 443}

      assert {:ok, ^actor} = HTTP.verify_request(conn)
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

      date = HTTPDate.format_rfc1123(DateTime.utc_now())
      digest = "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, ""))

      conn =
        Plug.Test.conn(:post, "/users/frank/inbox", "")
        |> Plug.Conn.assign(:raw_body, "")
        |> Plug.Conn.put_req_header("date", date)
        |> Plug.Conn.put_req_header("digest", digest)
        |> Plug.Conn.put_req_header(
          "signature",
          "Signature foo,keyId=\"#{user.ap_id}#main-key\",headers=\"(request-target) host date digest\",signature=\"AA==\""
        )

      assert {:error, :invalid_signature} = HTTP.verify_request(conn)
    end

    test "rejects duplicate signature parameters instead of accepting the last value" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = ""
      {:ok, signed} = HTTP.sign_request(user, "post", "https://local.example/inbox", body)

      ambiguous =
        "keyId=\"https://attacker.example/actor#main-key\"," <> signed.signature

      conn =
        Plug.Test.conn(:post, "/inbox", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("digest", signed.digest)
        |> Plug.Conn.put_req_header("content-length", signed.content_length)
        |> Plug.Conn.put_req_header("signature", ambiguous)

      conn = %{conn | host: "local.example", scheme: :https, port: 443}

      assert {:error, :invalid_signature} = HTTP.verify_request(conn)
    end

    test "rejects duplicate security headers instead of collapsing them" do
      {public_key, private_key} = Keys.generate_rsa_keypair()

      {:ok, user} =
        create_remote_user(%{
          public_key: public_key,
          private_key: private_key
        })

      body = ""
      {:ok, signed} = HTTP.sign_request(user, "post", "https://local.example/inbox", body)

      conn =
        Plug.Test.conn(:post, "/inbox", body)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("date", signed.date)
        |> Plug.Conn.put_req_header("digest", signed.digest)
        |> Plug.Conn.put_req_header("content-length", signed.content_length)
        |> Plug.Conn.put_req_header("signature", signed.signature)

      conn = %{
        conn
        | host: "local.example",
          scheme: :https,
          port: 443,
          req_headers: [{"signature", signed.signature} | conn.req_headers]
      }

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
