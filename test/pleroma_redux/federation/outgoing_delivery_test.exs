defmodule PleromaRedux.Federation.OutgoingDeliveryTest do
  use PleromaRedux.DataCase, async: true

  import Mox

  alias PleromaRedux.Pipeline
  alias PleromaRedux.Users

  test "local Follow delivers to remote inbox" do
    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote} =
      Users.create_user(%{
        nickname: "bob",
        ap_id: "https://remote.example/users/bob",
        inbox: "https://remote.example/users/bob/inbox",
        outbox: "https://remote.example/users/bob/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    follow = %{
      "id" => "https://local.example/activities/follow/1",
      "type" => "Follow",
      "actor" => local.ap_id,
      "object" => remote.ap_id
    }

    PleromaRedux.HTTP.Mock
    |> expect(:post, fn url, body, headers ->
      assert url == remote.inbox

      decoded = Jason.decode!(body)
      assert decoded["type"] == "Follow"
      assert decoded["actor"] == local.ap_id
      assert decoded["object"] == remote.ap_id

      expected_digest = "SHA-256=" <> (:crypto.hash(:sha256, body) |> Base.encode64())
      assert {"digest", expected_digest} in headers

      assert Enum.any?(headers, fn
               {"signature", value} ->
                 is_binary(value) and String.contains?(value, "keyId=\"#{local.ap_id}#main-key\"")

               _ ->
                 false
             end)

      {:ok, %{status: 202, body: "", headers: []}}
    end)

    assert {:ok, _} = Pipeline.ingest(follow, local: true)
  end

  test "local Create delivers to remote followers" do
    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote_follower} =
      Users.create_user(%{
        nickname: "carol",
        ap_id: "https://remote.example/users/carol",
        inbox: "https://remote.example/users/carol/inbox",
        outbox: "https://remote.example/users/carol/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    follow = %{
      "id" => "https://remote.example/activities/follow/1",
      "type" => "Follow",
      "actor" => remote_follower.ap_id,
      "object" => local.ap_id
    }

    assert {:ok, _} = Pipeline.ingest(follow, local: false)

    note = %{
      "id" => "https://local.example/objects/1",
      "type" => "Note",
      "attributedTo" => local.ap_id,
      "content" => "Hello followers"
    }

    create = %{
      "id" => "https://local.example/activities/create/1",
      "type" => "Create",
      "actor" => local.ap_id,
      "object" => note
    }

    PleromaRedux.HTTP.Mock
    |> expect(:post, fn url, body, _headers ->
      assert url == remote_follower.inbox

      decoded = Jason.decode!(body)
      assert decoded["type"] == "Create"
      assert decoded["actor"] == local.ap_id
      assert is_map(decoded["object"])

      {:ok, %{status: 202, body: "", headers: []}}
    end)

    assert {:ok, _} = Pipeline.ingest(create, local: true)
  end
end

