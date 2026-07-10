defmodule Egregoros.Federation.ActorDiscoveryTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Federation.ActorDiscovery
  alias Egregoros.Workers.FetchActor

  test "actor_ids extracts actor ids from actors, recipients, and mention tags" do
    activity = %{
      "actor" => "https://remote.example/users/alice",
      "attributedTo" => "https://remote.example/users/alice",
      "to" => [
        "https://www.w3.org/ns/activitystreams#Public",
        "https://remote.example/users/carol"
      ],
      "cc" => [
        "https://remote.example/users/alice/followers",
        "https://remote.example/users/dave"
      ],
      "tag" => [
        %{
          "type" => "Mention",
          "href" => "https://remote2.example/users/bob",
          "name" => "@bob@remote2.example"
        },
        %{
          "type" => "Hashtag",
          "href" => "https://remote.example/tags/test",
          "name" => "#test"
        }
      ]
    }

    assert Enum.sort(ActorDiscovery.actor_ids(activity)) ==
             Enum.sort([
               "https://remote.example/users/alice",
               "https://remote.example/users/carol",
               "https://remote.example/users/dave",
               "https://remote2.example/users/bob"
             ])
  end

  test "actor_ids includes issuer when actor is omitted" do
    activity = %{
      "issuer" => "https://remote.example/actors/instance",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    assert ActorDiscovery.actor_ids(activity) == ["https://remote.example/actors/instance"]
  end

  test "actor_ids extracts ids from lists, map shapes, and mention tags" do
    activity = %{
      "actor" => [
        %{"id" => "https://remote.example/users/actor-id"},
        %{"href" => "https://remote.example/users/actor-href"},
        "https://remote.example/users/actor-string"
      ],
      "to" => [
        %{"id" => "https://remote.example/users/recipient-id"},
        %{"href" => "https://remote.example/users/recipient-href"},
        " ",
        "https://www.w3.org/ns/activitystreams#Public",
        "https://remote.example/users/actor-string/followers"
      ],
      "tag" => [
        %{"type" => "Mention", "id" => "https://remote.example/users/tag-id"},
        %{"type" => "Mention", "href" => "https://remote.example/users/tag-href"},
        %{"type" => "Hashtag", "href" => "https://remote.example/tags/test"}
      ]
    }

    assert Enum.sort(ActorDiscovery.actor_ids(activity)) ==
             Enum.sort([
               "https://remote.example/users/actor-id",
               "https://remote.example/users/actor-href",
               "https://remote.example/users/actor-string",
               "https://remote.example/users/recipient-id",
               "https://remote.example/users/recipient-href",
               "https://remote.example/users/tag-id",
               "https://remote.example/users/tag-href"
             ])
  end

  test "enqueue/2 skips discovery for local activities" do
    activity = %{"actor" => "https://remote.example/users/alice"}

    assert :ok = ActorDiscovery.enqueue(activity, local: true)
    refute_enqueued(worker: FetchActor)
  end

  test "enqueue/2 enqueues fetch jobs for unknown remote actors" do
    actor_ap_id = "https://remote.example/users/alice"
    activity = %{"actor" => actor_ap_id}

    assert :ok = ActorDiscovery.enqueue(activity, local: false)

    assert_enqueued(worker: FetchActor, args: %{"ap_id" => actor_ap_id})
  end

  test "enqueue rejects one actor over the fan-out limit before creating jobs" do
    activity = %{
      "to" =>
        for index <- 1..51 do
          "https://remote#{index}.example/users/person"
        end
    }

    assert {:error, :actor_discovery_limit} =
             ActorDiscovery.enqueue(activity, local: false)

    refute_enqueued(worker: FetchActor)
  end

  test "enqueue accepts exactly the actor fan-out limit" do
    activity = %{
      "to" =>
        for index <- 1..50 do
          "https://remote#{index}.example/users/person"
        end
    }

    assert :ok = ActorDiscovery.enqueue(activity, local: false)
    assert length(all_enqueued(worker: FetchActor)) == 50
  end

  test "enqueue reserves a per-domain fetch budget before creating jobs" do
    expect(Egregoros.RateLimiter.Mock, :allow?, fn
      :actor_discovery_domain, "remote.example", 60, 60_000 ->
        {:error, :rate_limited}
    end)

    assert {:error, :rate_limited} =
             ActorDiscovery.enqueue(
               %{"actor" => "https://remote.example/users/alice"},
               local: false
             )

    refute_enqueued(worker: FetchActor)
  end

  test "enqueue/2 does not enqueue when the actor is already stored" do
    actor_ap_id = "https://remote.example/users/alice"

    {:ok, _user} =
      %Egregoros.User{}
      |> Egregoros.User.changeset(%{
        nickname: "alice",
        ap_id: actor_ap_id,
        inbox: actor_ap_id <> "/inbox",
        outbox: actor_ap_id <> "/outbox",
        public_key: "PUB",
        local: false
      })
      |> Egregoros.Repo.insert()

    activity = %{"actor" => actor_ap_id}

    assert :ok = ActorDiscovery.enqueue(activity, local: false)
    refute_enqueued(worker: FetchActor)
  end

  test "enqueue/2 ignores invalid actor ids" do
    assert :ok = ActorDiscovery.enqueue(%{"actor" => ""}, local: false)
    assert :ok = ActorDiscovery.enqueue(%{"actor" => "mailto:alice@remote.example"}, local: false)
    assert :ok = ActorDiscovery.enqueue(%{"actor" => "pleroma.example"}, local: false)

    refute_enqueued(worker: FetchActor)
  end

  test "actor_ids and enqueue handle invalid activities" do
    assert ActorDiscovery.actor_ids("invalid") == []
    assert :ok = ActorDiscovery.enqueue("invalid", local: false)
  end

  test "enqueue/1 uses local defaults" do
    actor_ap_id = "https://remote.example/users/alice"
    activity = %{"actor" => actor_ap_id}

    assert :ok = ActorDiscovery.enqueue(activity)
    refute_enqueued(worker: FetchActor)
  end
end
