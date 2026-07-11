defmodule EgregorosWeb.InboxControllerTest do
  use EgregorosWeb.ConnCase, async: false

  alias Egregoros.Keys
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.NotificationAudits
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.Objects
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo
  alias Egregoros.Relationships
  alias Egregoros.Users
  alias Egregoros.Workers.IngestActivity

  test "POST /users/:nickname/inbox ingests activity", %{conn: conn} do
    {:ok, frank} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, alice} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    :ok = follow!(frank.ap_id, alice.ap_id)

    note = %{
      "id" => "https://remote.example/objects/1",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello from remote"
    }

    create = %{
      "id" => "https://remote.example/activities/create/1",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(create)
      )
      |> post_signed("/users/frank/inbox", create)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      queue: "federation_incoming",
      args: %{"activity" => create, "inbox_user_ap_id" => frank.ap_id}
    )

    assert :ok =
             perform_job(IngestActivity, %{
               "activity" => create,
               "inbox_user_ap_id" => frank.ap_id
             })

    assert Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox binds a declared mini-app actor to its activated key", %{
    conn: conn
  } do
    enable_mini_apps()
    {:ok, frank} = Users.create_local_user("mini-app-pinned-key-recipient")
    actor = "https://app.example/ap/actor"
    {public_key, private_key} = Keys.generate_rsa_keypair()

    {:ok, _actor_user} =
      Users.create_user(%{
        nickname: "app",
        ap_id: actor,
        inbox: "https://app.example/ap/inbox",
        outbox: "https://app.example/ap/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(%{
                 "version" => "1",
                 "name" => "Pinned app",
                 "homeUrl" => "https://app.example/",
                 "activityPub" => %{
                   "actorUrl" => actor,
                   "publicNotes" => true,
                   "transactionalMentions" => false
                 },
                 "capabilities" => []
               }),
               "https://app.example/.well-known/fediverse-miniapp.json"
             )

    assert {:ok, declaration, :created} = Declarations.ensure(manifest)

    declaration
    |> Ecto.Changeset.change(%{
      activity_pub_actor_fingerprint: :crypto.hash(:sha256, "actor-document"),
      activity_pub_actor_activated_at: DateTime.utc_now(),
      activity_pub_actor_key_id: actor <> "#main-key",
      activity_pub_actor_key_fingerprint: rsa_key_fingerprint(public_key),
      activity_pub_actor_public_key_pem: public_key
    })
    |> Repo.update!()

    valid = public_create(actor, "pinned-valid")
    path = "/users/#{frank.nickname}/inbox"

    conn =
      conn
      |> sign_request(
        "post",
        path,
        private_key,
        actor <> "#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(valid)
      )
      |> post_signed(path, valid)

    assert response(conn, 202)

    {rotated_public_key, rotated_private_key} = Keys.generate_rsa_keypair()

    assert {:ok, _rotated_actor} =
             Users.upsert_user(%{
               ap_id: actor,
               public_key: rotated_public_key,
               private_key: rotated_private_key
             })

    rotated = public_create(actor, "pinned-rotated")

    conn =
      build_conn()
      |> sign_request(
        "post",
        path,
        rotated_private_key,
        actor <> "#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(rotated)
      )
      |> post_signed(path, rotated)

    assert response(conn, 401)
    refute_enqueued(worker: IngestActivity, args: %{"activity" => rotated})
  end

  test "signed transactional delivery is consented, auditable, and silently revoked", %{
    conn: conn
  } do
    enable_mini_apps()
    {:ok, recipient} = Users.create_local_user("mini-app-signed-transaction-recipient")
    actor = "https://alerts.example/ap/actor"
    origin = "https://alerts.example"
    {public_key, private_key} = Keys.generate_rsa_keypair()

    {:ok, _actor_user} =
      Users.create_user(%{
        nickname: "alerts",
        ap_id: actor,
        inbox: origin <> "/ap/inbox",
        outbox: origin <> "/ap/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(%{
                 "version" => "1",
                 "name" => "Signed alerts",
                 "homeUrl" => origin <> "/",
                 "oauth" => %{
                   "redirectUris" => [origin <> "/oauth/callback"],
                   "scopes" => ["read"]
                 },
                 "activityPub" => %{
                   "actorUrl" => actor,
                   "publicNotes" => false,
                   "transactionalMentions" => true
                 },
                 "capabilities" => []
               }),
               origin <> "/.well-known/fediverse-miniapp.json"
             )

    assert {:ok, registration} = OAuthRegistrations.register(manifest)
    declaration = Declarations.get_by_origin(origin)

    declaration
    |> Ecto.Changeset.change(%{
      activity_pub_actor_fingerprint: :crypto.hash(:sha256, "signed-alerts-actor"),
      activity_pub_actor_activated_at: DateTime.utc_now(),
      activity_pub_actor_key_id: actor <> "#main-key",
      activity_pub_actor_key_fingerprint: rsa_key_fingerprint(public_key),
      activity_pub_actor_public_key_pem: public_key
    })
    |> Repo.update!()

    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    authorize_mini_app!(application, recipient, origin)
    assert {:ok, _consent} = NotificationConsents.decide(recipient.id, origin, :granted)

    path = "/users/#{recipient.nickname}/inbox"
    allowed = transactional_create(actor, recipient.ap_id, "signed-allowed")

    conn =
      conn
      |> sign_request(
        "post",
        path,
        private_key,
        actor <> "#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(allowed)
      )
      |> post_signed(path, allowed)

    assert response(conn, 202)

    assert :ok =
             perform_job(IngestActivity, %{
               "activity" => allowed,
               "inbox_user_ap_id" => recipient.ap_id
             })

    assert Objects.get_by_ap_id(allowed["object"]["id"])
    assert hd(NotificationAudits.list_for_user(recipient)).event == :delivery_accepted

    assert :ok = NotificationConsents.revoke(recipient.id, origin)
    revoked = transactional_create(actor, recipient.ap_id, "signed-revoked")

    conn =
      build_conn()
      |> sign_request(
        "post",
        path,
        private_key,
        actor <> "#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(revoked)
      )
      |> post_signed(path, revoked)

    assert response(conn, 202)

    assert :ok =
             perform_job(IngestActivity, %{
               "activity" => revoked,
               "inbox_user_ap_id" => recipient.ap_id
             })

    refute Objects.get_by_ap_id(revoked["object"]["id"])
    assert hd(NotificationAudits.list_for_user(recipient)).event == :delivery_suppressed
  end

  test "POST /users/:nickname/inbox returns 429 when rate limited", %{conn: conn} do
    {:ok, frank} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _alice} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    note = %{
      "id" => "https://remote.example/objects/1-rate-limit",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello from remote"
    }

    create = %{
      "id" => "https://remote.example/activities/create/1-rate-limit",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    path = "/users/#{frank.nickname}/inbox"

    expect(Egregoros.RateLimiter.Mock, :allow?, fn :inbox, key, _limit, _interval_ms ->
      assert is_binary(key)
      assert String.contains?(key, path)
      {:error, :rate_limited}
    end)

    conn =
      conn
      |> sign_request(
        "post",
        path,
        private_key,
        "https://remote.example/users/alice#main-key"
      )
      |> post_signed(path, create)

    assert response(conn, 429)
    refute_enqueued(worker: IngestActivity)
    refute Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox discards a Follow not targeting that inbox user", %{
    conn: conn
  } do
    {:ok, frank} = Users.create_local_user("frank")
    {:ok, bob} = Users.create_local_user("bob")

    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    follow = %{
      "id" => "https://remote.example/activities/follow/1",
      "type" => "Follow",
      "actor" => "https://remote.example/users/alice",
      "object" => bob.ap_id
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(follow)
      )
      |> post_signed("/users/frank/inbox", follow)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      queue: "federation_incoming",
      args: %{"activity" => follow, "inbox_user_ap_id" => frank.ap_id}
    )

    assert {:discard, :not_targeted} =
             perform_job(IngestActivity, %{
               "activity" => follow,
               "inbox_user_ap_id" => frank.ap_id
             })

    refute Objects.get_by_ap_id(follow["id"])
    refute Relationships.get_by_type_actor_object("Follow", follow["actor"], bob.ap_id)
  end

  test "POST /users/:nickname/inbox discards a Create not targeting that inbox user", %{
    conn: conn
  } do
    {:ok, frank} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    note = %{
      "id" => "https://remote.example/objects/1-not-targeted",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello from remote"
    }

    create = %{
      "id" => "https://remote.example/activities/create/1-not-targeted",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(create)
      )
      |> post_signed("/users/frank/inbox", create)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      args: %{"activity" => create, "inbox_user_ap_id" => frank.ap_id}
    )

    assert {:discard, :not_targeted} =
             perform_job(IngestActivity, %{
               "activity" => create,
               "inbox_user_ap_id" => frank.ap_id
             })

    refute Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox discards a Like not targeting that inbox user", %{
    conn: conn
  } do
    {:ok, frank} = Users.create_local_user("frank")
    {:ok, bob} = Users.create_local_user("bob")

    {:ok, _} =
      Objects.upsert_object(%{
        ap_id: "https://egregoros.example/objects/bob-post",
        type: "Note",
        actor: bob.ap_id,
        object: nil,
        data: %{"id" => "https://egregoros.example/objects/bob-post", "type" => "Note"},
        local: true
      })

    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    like = %{
      "id" => "https://remote.example/activities/like/1-not-targeted",
      "type" => "Like",
      "actor" => "https://remote.example/users/alice",
      "object" => "https://egregoros.example/objects/bob-post"
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(like)
      )
      |> post_signed("/users/frank/inbox", like)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      args: %{"activity" => like, "inbox_user_ap_id" => frank.ap_id}
    )

    assert {:discard, :not_targeted} =
             perform_job(IngestActivity, %{
               "activity" => like,
               "inbox_user_ap_id" => frank.ap_id
             })

    refute Objects.get_by_ap_id(like["id"])
    refute Relationships.get_by_type_actor_object("Like", like["actor"], like["object"])
  end

  test "POST /inbox ingests public activities for the instance actor", %{conn: conn} do
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    like = %{
      "id" => "https://remote.example/activities/like/instance-inbox-public",
      "type" => "Like",
      "actor" => "https://remote.example/users/alice",
      "object" => "https://somewhere.example/objects/1",
      "cc" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(like)
      )
      |> post_signed("/inbox", like)

    assert response(conn, 202)

    args =
      all_enqueued(worker: IngestActivity)
      |> Enum.map(& &1.args)
      |> Enum.find(fn
        %{"activity" => %{"id" => "https://remote.example/activities/like/instance-inbox-public"}} ->
          true

        _ ->
          false
      end)

    assert is_map(args)
    refute Map.has_key?(args, "inbox_user_ap_id")

    assert :ok = perform_job(IngestActivity, args)
    assert Objects.get_by_ap_id(like["id"])
  end

  test "POST /inbox includes inbox_user_ap_id for non-public instance actor ingestion", %{
    conn: conn
  } do
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    like = %{
      "id" => "https://remote.example/activities/like/instance-inbox-non-public",
      "type" => "Like",
      "actor" => "https://remote.example/users/alice",
      "object" => "https://remote.example/objects/unknown"
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(like)
      )
      |> post_signed("/inbox", like)

    assert response(conn, 202)

    args =
      all_enqueued(worker: IngestActivity)
      |> Enum.map(& &1.args)
      |> Enum.find(fn
        %{
          "activity" => %{
            "id" => "https://remote.example/activities/like/instance-inbox-non-public"
          }
        } ->
          true

        _ ->
          false
      end)

    assert is_map(args)
    expected_instance_actor_ap_id = EgregorosWeb.Endpoint.url()
    assert %{"inbox_user_ap_id" => ^expected_instance_actor_ap_id} = args
  end

  test "POST /users/:nickname/inbox ingests public activities for the internal fetch actor", %{
    conn: conn
  } do
    {:ok, _internal} = Users.get_or_create_local_user("internal.fetch")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    like = %{
      "id" => "https://remote.example/activities/like/internal-fetch-public",
      "type" => "Like",
      "actor" => "https://remote.example/users/alice",
      "object" => "https://somewhere.example/objects/1",
      "cc" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/internal.fetch/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(like)
      )
      |> post_signed("/users/internal.fetch/inbox", like)

    assert response(conn, 202)

    args =
      all_enqueued(worker: IngestActivity)
      |> Enum.map(& &1.args)
      |> Enum.find(fn
        %{"activity" => %{"id" => "https://remote.example/activities/like/internal-fetch-public"}} ->
          true

        _ ->
          false
      end)

    assert is_map(args)
    refute Map.has_key?(args, "inbox_user_ap_id")

    assert :ok = perform_job(IngestActivity, args)
    assert Objects.get_by_ap_id(like["id"])
  end

  test "POST /users/:nickname/inbox treats an activity as public when its object is addressed to Public",
       %{
         conn: conn
       } do
    {:ok, _internal} = Users.get_or_create_local_user("internal.fetch")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    note = %{
      "id" => "https://remote.example/objects/internal-fetch-public-object",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "hello",
      "to" => [%{"id" => "https://www.w3.org/ns/activitystreams#Public"}]
    }

    create = %{
      "id" => "https://remote.example/activities/create/internal-fetch-public-object",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/internal.fetch/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(create)
      )
      |> post_signed("/users/internal.fetch/inbox", create)

    assert response(conn, 202)

    args =
      all_enqueued(worker: IngestActivity)
      |> Enum.map(& &1.args)
      |> Enum.find(fn
        %{
          "activity" => %{
            "id" => "https://remote.example/activities/create/internal-fetch-public-object"
          }
        } ->
          true

        _ ->
          false
      end)

    assert is_map(args)
    refute Map.has_key?(args, "inbox_user_ap_id")

    assert :ok = perform_job(IngestActivity, args)
    assert Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox includes inbox_user_ap_id for non-public internal fetch ingestion",
       %{
         conn: conn
       } do
    {:ok, _internal} = Users.get_or_create_local_user("internal.fetch")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    like = %{
      "id" => "https://remote.example/activities/like/internal-fetch-non-public",
      "type" => "Like",
      "actor" => "https://remote.example/users/alice",
      "object" => "https://remote.example/objects/unknown"
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/internal.fetch/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(like)
      )
      |> post_signed("/users/internal.fetch/inbox", like)

    assert response(conn, 202)

    args =
      all_enqueued(worker: IngestActivity)
      |> Enum.map(& &1.args)
      |> Enum.find(fn
        %{
          "activity" => %{
            "id" => "https://remote.example/activities/like/internal-fetch-non-public"
          }
        } ->
          true

        _ ->
          false
      end)

    assert is_map(args)
    expected_internal_fetch_ap_id = EgregorosWeb.Endpoint.url() <> "/users/internal.fetch"
    assert %{"inbox_user_ap_id" => ^expected_internal_fetch_ap_id} = args
  end

  test "POST /users/:nickname/inbox discards an Accept not targeting that inbox user", %{
    conn: conn
  } do
    {:ok, frank} = Users.create_local_user("frank")
    {:ok, bob} = Users.create_local_user("bob")

    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, alice} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    {:ok, _} =
      Objects.upsert_object(%{
        ap_id: "https://egregoros.example/activities/follow/bob-to-alice",
        type: "Follow",
        actor: bob.ap_id,
        object: alice.ap_id,
        data: %{
          "id" => "https://egregoros.example/activities/follow/bob-to-alice",
          "type" => "Follow",
          "actor" => bob.ap_id,
          "object" => alice.ap_id
        },
        local: true
      })

    accept = %{
      "id" => "https://remote.example/activities/accept/1-not-targeted",
      "type" => "Accept",
      "actor" => "https://remote.example/users/alice",
      "object" => "https://egregoros.example/activities/follow/bob-to-alice"
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(accept)
      )
      |> post_signed("/users/frank/inbox", accept)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      args: %{"activity" => accept, "inbox_user_ap_id" => frank.ap_id}
    )

    assert {:discard, :not_targeted} =
             perform_job(IngestActivity, %{
               "activity" => accept,
               "inbox_user_ap_id" => frank.ap_id
             })

    refute Objects.get_by_ap_id(accept["id"])
  end

  test "POST /users/:nickname/inbox accepts a Create with attachments and blank content", %{
    conn: conn
  } do
    {:ok, frank} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, alice} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    :ok = follow!(frank.ap_id, alice.ap_id)

    note = %{
      "id" => "https://remote.example/objects/1-attachment-only",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "",
      "attachment" => [
        %{
          "type" => "Document",
          "mediaType" => "image/webp",
          "url" => "https://cdn.remote.example/media/1.webp",
          "name" => ""
        }
      ]
    }

    create = %{
      "id" => "https://remote.example/activities/create/1-attachment-only",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(create)
      )
      |> post_signed("/users/frank/inbox", create)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      args: %{"activity" => create, "inbox_user_ap_id" => frank.ap_id}
    )

    assert :ok =
             perform_job(IngestActivity, %{
               "activity" => create,
               "inbox_user_ap_id" => frank.ap_id
             })

    object = Objects.get_by_ap_id(note["id"])
    assert object
    assert object.data["content"] == ""
    assert is_list(object.data["attachment"])

    assert Enum.at(object.data["attachment"], 0)["url"] ==
             "https://cdn.remote.example/media/1.webp"
  end

  test "POST /users/:nickname/inbox accepts signature with digest and host", %{conn: conn} do
    {:ok, frank} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, alice} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    :ok = follow!(frank.ap_id, alice.ap_id)

    note = %{
      "id" => "https://remote.example/objects/1-digest",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello with digest"
    }

    create = %{
      "id" => "https://remote.example/activities/create/1-digest",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    body = Jason.encode!(create)
    headers = ["(request-target)", "host", "date", "digest", "content-length"]

    conn =
      conn
      |> put_req_header("content-type", "application/activity+json")
      |> put_req_header("accept", "application/activity+json")
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        headers,
        body
      )
      |> post_signed("/users/frank/inbox", body)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      args: %{"activity" => create, "inbox_user_ap_id" => frank.ap_id}
    )

    assert :ok =
             perform_job(IngestActivity, %{
               "activity" => create,
               "inbox_user_ap_id" => frank.ap_id
             })

    assert Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox accepts signature header without scheme prefix", %{conn: conn} do
    {:ok, frank} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, alice} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    :ok = follow!(frank.ap_id, alice.ap_id)

    note = %{
      "id" => "https://remote.example/objects/1-signature-header",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello via signature header"
    }

    create = %{
      "id" => "https://remote.example/activities/create/1-signature-header",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        ["(request-target)", "host", "date", "digest"],
        Jason.encode!(create)
      )
      |> move_authorization_to_signature_header()
      |> post_signed("/users/frank/inbox", create)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      args: %{"activity" => create, "inbox_user_ap_id" => frank.ap_id}
    )

    assert :ok =
             perform_job(IngestActivity, %{
               "activity" => create,
               "inbox_user_ap_id" => frank.ap_id
             })

    assert Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox accepts signature behind https proxy (x-forwarded headers)",
       %{
         conn: conn
       } do
    stub(Egregoros.Config.Mock, :get, fn
      :public_host_aliases, [] -> ["egregoros.ngrok.dev"]
      :trusted_proxies, [] -> ["10.0.0.0/8"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, frank} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, alice} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    :ok = follow!(frank.ap_id, alice.ap_id)

    note = %{
      "id" => "https://remote.example/objects/1-proxy",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello through proxy"
    }

    create = %{
      "id" => "https://remote.example/activities/create/1-proxy",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    body = Jason.encode!(create)
    headers = ["(request-target)", "host", "date", "digest", "content-length"]
    headers = Enum.map(headers, &String.downcase/1)

    date = date_header()
    host = "egregoros.ngrok.dev"
    digest = digest_header(body)
    content_length = Integer.to_string(byte_size(body))

    signature_string =
      signature_string(headers, "post", "/users/frank/inbox", %{
        "date" => date,
        "host" => host,
        "content-length" => content_length,
        "digest" => digest
      })

    [entry] = :public_key.pem_decode(private_key)
    private_key = :public_key.pem_entry_decode(entry)
    signature = :public_key.sign(signature_string, :sha256, private_key)
    signature_b64 = Base.encode64(signature)

    header =
      "keyId=\"https://remote.example/users/alice#main-key\"," <>
        "algorithm=\"rsa-sha256\"," <>
        "headers=\"#{Enum.join(headers, " ")}\"," <>
        "signature=\"#{signature_b64}\""

    conn =
      conn
      |> Map.put(:scheme, :http)
      |> Map.put(:host, host)
      |> Map.put(:port, 4000)
      |> Map.put(:remote_ip, {10, 0, 0, 2})
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-port", "443")
      |> put_req_header("content-type", "application/activity+json")
      |> put_req_header("accept", "application/activity+json")
      |> put_req_header("date", date)
      |> put_req_header("digest", digest)
      |> put_req_header("content-length", content_length)
      |> put_req_header("signature", header)
      |> post_signed("/users/frank/inbox", body)

    assert response(conn, 202)

    assert_enqueued(
      worker: IngestActivity,
      args: %{"activity" => create, "inbox_user_ap_id" => frank.ap_id}
    )

    assert :ok =
             perform_job(IngestActivity, %{
               "activity" => create,
               "inbox_user_ap_id" => frank.ap_id
             })

    assert Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox rejects mismatched digest", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    note = %{
      "id" => "https://remote.example/objects/1-digest-mismatch",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Original content"
    }

    tampered_note = Map.put(note, "content", "Tampered content")

    signed_create = %{
      "id" => "https://remote.example/activities/create/1-digest-mismatch",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    tampered_create = %{
      "id" => "https://remote.example/activities/create/1-digest-mismatch",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => tampered_note
    }

    signed_body = Jason.encode!(signed_create)
    sent_body = Jason.encode!(tampered_create)

    headers = ["(request-target)", "host", "date", "digest", "content-length"]

    conn =
      conn
      |> put_req_header("content-type", "application/activity+json")
      |> put_req_header("accept", "application/activity+json")
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key",
        headers,
        signed_body
      )
      |> post_signed("/users/frank/inbox", sent_body)

    assert response(conn, 401)
    refute Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox rejects signature actor mismatch", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    note = %{
      "id" => "https://remote.example/objects/1-actor-mismatch",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/bob",
      "content" => "Hello from bob"
    }

    create = %{
      "id" => "https://remote.example/activities/create/1-actor-mismatch",
      "type" => "Create",
      "actor" => "https://remote.example/users/bob",
      "object" => note
    }

    conn =
      conn
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key"
      )
      |> post_signed("/users/frank/inbox", create)

    assert response(conn, 401)
    refute Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox rejects old date signature", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("frank")
    {public_key, private_key} = Egregoros.Keys.generate_rsa_keypair()

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    note = %{
      "id" => "https://remote.example/objects/1-old-date",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Old date note"
    }

    create = %{
      "id" => "https://remote.example/activities/create/1-old-date",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    old_date = DateTime.utc_now() |> DateTime.add(-400, :second) |> date_header()

    conn =
      conn
      |> put_req_header("date", old_date)
      |> sign_request(
        "post",
        "/users/frank/inbox",
        private_key,
        "https://remote.example/users/alice#main-key"
      )
      |> post_signed("/users/frank/inbox", create)

    assert response(conn, 401)
    refute Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox rejects invalid signature", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("frank")

    note = %{
      "id" => "https://remote.example/objects/2",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello from remote"
    }

    create = %{
      "id" => "https://remote.example/activities/create/2",
      "type" => "Create",
      "actor" => "https://remote.example/users/alice",
      "object" => note
    }

    conn = post(conn, "/users/frank/inbox", create)
    assert response(conn, 401)

    refute Objects.get_by_ap_id(note["id"])
  end

  defp follow!(follower_ap_id, followed_ap_id)
       when is_binary(follower_ap_id) and is_binary(followed_ap_id) do
    {:ok, _} =
      Relationships.upsert_relationship(%{
        type: "Follow",
        actor: follower_ap_id,
        object: followed_ap_id,
        activity_ap_id: Ecto.UUID.generate()
      })

    :ok
  end

  defp sign_request(
         conn,
         method,
         path,
         private_key_pem,
         key_id,
         headers \\ ["(request-target)", "date"],
         body \\ nil
       ) do
    provided_body = body
    headers = Enum.map(headers, &String.downcase/1)
    body = body || ""
    date = Plug.Conn.get_req_header(conn, "date") |> List.first() || date_header()
    host = host_header(conn)
    content_length = Integer.to_string(byte_size(body))
    digest = digest_header(body)

    conn =
      conn
      |> maybe_put_header(headers, "date", date)
      |> maybe_put_header(headers, "host", host)
      |> maybe_put_header(headers, "content-length", content_length)
      |> maybe_put_header(headers, "digest", digest)

    signature_string =
      signature_string(headers, method, path, %{
        "date" => date,
        "host" => host,
        "content-length" => content_length,
        "digest" => digest
      })

    [entry] = :public_key.pem_decode(private_key_pem)
    private_key = :public_key.pem_entry_decode(entry)
    signature = :public_key.sign(signature_string, :sha256, private_key)
    signature_b64 = Base.encode64(signature)

    header =
      "Signature " <>
        "keyId=\"#{key_id}\"," <>
        "algorithm=\"rsa-sha256\"," <>
        "headers=\"#{Enum.join(headers, " ")}\"," <>
        "signature=\"#{signature_b64}\""

    conn = Plug.Conn.put_req_header(conn, "authorization", header)

    if is_nil(provided_body) do
      conn
    else
      conn
      |> Plug.Conn.assign(:signed_test_body, body)
      |> Plug.Conn.put_req_header("content-type", "application/activity+json")
    end
  end

  defp post_signed(conn, path, params) when is_binary(params), do: post(conn, path, params)

  defp post_signed(conn, path, params) do
    post(conn, path, Map.get(conn.assigns, :signed_test_body, params))
  end

  defp move_authorization_to_signature_header(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Signature " <> rest] ->
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.put_req_header("signature", rest)

      _ ->
        conn
    end
  end

  defp signature_string(headers, method, path, values) do
    headers
    |> Enum.map(fn
      "(request-target)" -> "(request-target): #{String.downcase(method)} " <> path
      "@request-target" -> "@request-target: #{String.downcase(method)} " <> path
      header -> "#{header}: #{Map.get(values, header, "")}"
    end)
    |> Enum.join("\n")
  end

  defp maybe_put_header(conn, headers, header, value) do
    cond do
      header not in headers ->
        conn

      header == "host" ->
        %{conn | host: value}

      true ->
        Plug.Conn.put_req_header(conn, header, value)
    end
  end

  defp digest_header(body) do
    "SHA-256=" <> (:crypto.hash(:sha256, body) |> Base.encode64())
  end

  defp host_header(conn) do
    default_port =
      case conn.scheme do
        :https -> 443
        _ -> 80
      end

    if conn.port == default_port or is_nil(conn.port) do
      conn.host
    else
      "#{conn.host}:#{conn.port}"
    end
  end

  defp date_header do
    date_header(DateTime.utc_now())
  end

  defp date_header(%DateTime{} = dt) do
    year = dt.year
    month = dt.month
    day = dt.day
    hour = dt.hour
    minute = dt.minute
    second = dt.second

    weekday =
      case :calendar.day_of_the_week({year, month, day}) do
        1 -> "Mon"
        2 -> "Tue"
        3 -> "Wed"
        4 -> "Thu"
        5 -> "Fri"
        6 -> "Sat"
        7 -> "Sun"
      end

    month_name =
      case month do
        1 -> "Jan"
        2 -> "Feb"
        3 -> "Mar"
        4 -> "Apr"
        5 -> "May"
        6 -> "Jun"
        7 -> "Jul"
        8 -> "Aug"
        9 -> "Sep"
        10 -> "Oct"
        11 -> "Nov"
        12 -> "Dec"
      end

    :io_lib.format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT", [
      weekday,
      day,
      month_name,
      year,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end

  defp public_create(actor, suffix) do
    public = "https://www.w3.org/ns/activitystreams#Public"

    %{
      "id" => "https://app.example/ap/create/#{suffix}",
      "type" => "Create",
      "actor" => actor,
      "to" => [public],
      "object" => %{
        "id" => "https://app.example/ap/notes/#{suffix}",
        "type" => "Note",
        "attributedTo" => actor,
        "to" => [public],
        "content" => "Public announcement"
      }
    }
  end

  defp transactional_create(actor, recipient, suffix) do
    %{
      "id" => "https://alerts.example/ap/create/#{suffix}",
      "type" => "Create",
      "actor" => actor,
      "to" => [recipient],
      "cc" => [],
      "object" => %{
        "id" => "https://alerts.example/ap/notes/#{suffix}",
        "type" => "Note",
        "attributedTo" => actor,
        "to" => [recipient],
        "cc" => [],
        "content" => "Transactional alert",
        "tag" => [%{"type" => "Mention", "href" => recipient}]
      }
    }
  end

  defp authorize_mini_app!(application, user, origin) do
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               origin <> "/oauth/callback",
               "read",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, _token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "redirect_uri" => origin <> "/oauth/callback",
               "code_verifier" => verifier
             })
  end

  defp rsa_key_fingerprint(pem) do
    [entry] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)
    der = :public_key.der_encode(:RSAPublicKey, key)
    :crypto.hash(:sha256, der)
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
