defmodule Egregoros.Workers.RefreshRemoteFollowingGraphTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Relationships
  alias Egregoros.Workers.FetchActor
  alias Egregoros.Workers.RefreshRemoteFollowingGraph

  test "fetches following collection items and stores a follow graph" do
    actor_ap_id = "https://remote.example/users/bob"
    following_root = actor_ap_id <> "/following"
    first_page = following_root <> "?page=true"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      cond do
        url == actor_ap_id ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => actor_ap_id,
               "type" => "Person",
               "following" => following_root
             },
             headers: []
           }}

        url == following_root ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollection",
               "first" => first_page
             },
             headers: []
           }}

        url == first_page ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollectionPage",
               "orderedItems" => [
                 "https://other.example/users/alice",
                 %{"id" => "https://third.example/users/charlie"}
               ]
             },
             headers: []
           }}

        true ->
          flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok =
             perform_job(RefreshRemoteFollowingGraph, %{
               "ap_id" => actor_ap_id,
               "max_pages" => 2,
               "max_items" => 10
             })

    assert Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://other.example/users/alice"
           )

    assert Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://third.example/users/charlie"
           )

    assert_enqueued(worker: FetchActor, args: %{"ap_id" => "https://other.example/users/alice"})
    assert_enqueued(worker: FetchActor, args: %{"ap_id" => "https://third.example/users/charlie"})
  end

  test "follows next links, resolves relative urls, filters unsafe ids, and replaces stale edges" do
    actor_ap_id = "https://remote.example/users/bob"
    following_url = "https://remote.example/users/bob/following"
    next_page = following_url <> "?page=2"

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "GraphFollow",
               actor: actor_ap_id,
               object: "https://stale.example/users/stale",
               activity_ap_id: nil
             })

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      cond do
        url == actor_ap_id ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => actor_ap_id,
               "type" => "Person",
               "following" => "/users/bob/following"
             },
             headers: []
           }}

        url == following_url ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollectionPage",
               "items" => [
                 "https://other.example/users/alice",
                 "http://127.0.0.1/users/nope"
               ],
               "next" => next_page
             },
             headers: []
           }}

        url == next_page ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollectionPage",
               "items" => [
                 %{"href" => "https://third.example/users/charlie"}
               ]
             },
             headers: []
           }}

        true ->
          flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok =
             perform_job(RefreshRemoteFollowingGraph, %{
               "ap_id" => actor_ap_id,
               "max_pages" => 2,
               "max_items" => 10
             })

    refute Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://stale.example/users/stale"
           )

    assert Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://other.example/users/alice"
           )

    assert Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://third.example/users/charlie"
           )

    refute_enqueued(worker: FetchActor, args: %{"ap_id" => "http://127.0.0.1/users/nope"})
  end

  test "returns ok when the actor is missing" do
    actor_ap_id = "https://missing.example/users/bob"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      if url == actor_ap_id do
        {:ok, %{status: 404, body: "Not found", headers: []}}
      else
        flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok = perform_job(RefreshRemoteFollowingGraph, %{"ap_id" => actor_ap_id})
  end

  test "returns ok for unsafe actor urls" do
    assert :ok =
             perform_job(RefreshRemoteFollowingGraph, %{
               "ap_id" => "http://127.0.0.1/users/bob"
             })
  end

  test "returns ok for invalid actor json" do
    actor_ap_id = "https://remote.example/users/bob"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      if url == actor_ap_id do
        {:ok, %{status: 200, body: "not json", headers: []}}
      else
        flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok = perform_job(RefreshRemoteFollowingGraph, %{"ap_id" => actor_ap_id})
  end

  test "returns ok when the actor response body is not json" do
    actor_ap_id = "https://remote.example/users/bob"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      if url == actor_ap_id do
        {:ok, %{status: 200, body: 123, headers: []}}
      else
        flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok = perform_job(RefreshRemoteFollowingGraph, %{"ap_id" => actor_ap_id})
  end

  test "returns rate_limited when SignedFetch is rate limited" do
    actor_ap_id = "https://remote.example/users/bob"

    expect(Egregoros.RateLimiter.Mock, :allow?, fn :signed_fetch, key, _limit, _interval_ms ->
      assert String.contains?(key, "remote.example")
      {:error, :rate_limited}
    end)

    expect(Egregoros.HTTP.Mock, :get, 0, fn _url, _headers ->
      flunk("unexpected HTTP GET during RefreshRemoteFollowingGraph.perform/1")
    end)

    assert {:error, :rate_limited} =
             perform_job(RefreshRemoteFollowingGraph, %{
               "ap_id" => actor_ap_id,
               "max_pages" => 1,
               "max_items" => 1
             })
  end

  test "clears stale edges when the following collection has no items" do
    actor_ap_id = "https://remote.example/users/bob"
    following_url = "https://remote.example/users/bob/following"

    assert {:ok, _} =
             Relationships.upsert_relationship(%{
               type: "GraphFollow",
               actor: actor_ap_id,
               object: "https://stale.example/users/stale",
               activity_ap_id: nil
             })

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      cond do
        url == actor_ap_id ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => actor_ap_id,
               "type" => "Person",
               "following" => %{"href" => "/users/bob/following"}
             },
             headers: []
           }}

        url == following_url ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollection",
               "totalItems" => 0
             },
             headers: []
           }}

        true ->
          flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok =
             perform_job(RefreshRemoteFollowingGraph, %{
               "ap_id" => actor_ap_id,
               "max_pages" => "20",
               "max_items" => "1000"
             })

    refute Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://stale.example/users/stale"
           )

    refute_enqueued(worker: FetchActor)
  end

  test "parses id/href/url map forms in collections" do
    actor_ap_id = "https://remote.example/users/bob"
    following_url = "https://remote.example/users/bob/following"
    next_page = following_url <> "?page=2"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      cond do
        url == actor_ap_id ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => actor_ap_id,
               "type" => "Person",
               "following" => %{"id" => following_url}
             },
             headers: []
           }}

        url == following_url ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollectionPage",
               "items" => [
                 %{"url" => "https://other.example/users/alice"}
               ],
               "next" => %{"id" => next_page}
             },
             headers: []
           }}

        url == next_page ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollectionPage",
               "items" => [
                 %{"url" => %{"href" => "https://third.example/users/charlie"}}
               ]
             },
             headers: []
           }}

        true ->
          flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok =
             perform_job(RefreshRemoteFollowingGraph, %{
               "ap_id" => actor_ap_id,
               "max_pages" => "not-an-int",
               "max_items" => "not-an-int"
             })

    assert Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://other.example/users/alice"
           )

    assert Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://third.example/users/charlie"
           )
  end

  test "discards invalid args" do
    assert {:discard, :invalid_args} = RefreshRemoteFollowingGraph.perform(%Oban.Job{args: %{}})

    assert {:discard, :invalid_args} =
             RefreshRemoteFollowingGraph.perform(%Oban.Job{args: %{"ap_id" => 1}})
  end

  test "avoids loops when a collection page points next to itself" do
    actor_ap_id = "https://remote.example/users/bob"
    following_url = "https://remote.example/users/bob/following"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      cond do
        url == actor_ap_id ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => actor_ap_id,
               "type" => "Person",
               "following" => following_url
             },
             headers: []
           }}

        url == following_url ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollectionPage",
               "items" => ["https://other.example/users/alice"],
               "next" => following_url
             },
             headers: []
           }}

        true ->
          flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok =
             perform_job(RefreshRemoteFollowingGraph, %{
               "ap_id" => actor_ap_id,
               "max_pages" => 3,
               "max_items" => 10
             })

    assert Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://other.example/users/alice"
           )
  end

  test "returns ok for blank ap_id" do
    assert :ok = perform_job(RefreshRemoteFollowingGraph, %{"ap_id" => ""})
  end

  test "returns ok when the actor has no following collection url" do
    actor_ap_id = "https://remote.example/users/bob"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      if url == actor_ap_id do
        {:ok,
         %{
           status: 200,
           body: %{
             "id" => actor_ap_id,
             "type" => "Person"
           },
           headers: []
         }}
      else
        flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok = perform_job(RefreshRemoteFollowingGraph, %{"ap_id" => actor_ap_id})
  end

  test "respects max_pages when fetching a following collection" do
    actor_ap_id = "https://remote.example/users/bob"
    following_url = "https://remote.example/users/bob/following"
    next_page = following_url <> "?page=2"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      cond do
        url == actor_ap_id ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => actor_ap_id,
               "type" => "Person",
               "following" => following_url
             },
             headers: []
           }}

        url == following_url ->
          {:ok,
           %{
             status: 200,
             body: %{
               "type" => "OrderedCollectionPage",
               "items" => ["https://other.example/users/alice"],
               "next" => next_page
             },
             headers: []
           }}

        true ->
          flunk("unexpected HTTP GET to #{url}")
      end
    end)

    assert :ok =
             perform_job(RefreshRemoteFollowingGraph, %{
               "ap_id" => actor_ap_id,
               "max_pages" => 1,
               "max_items" => 10
             })

    assert Relationships.get_by_type_actor_object(
             "GraphFollow",
             actor_ap_id,
             "https://other.example/users/alice"
           )
  end
end
