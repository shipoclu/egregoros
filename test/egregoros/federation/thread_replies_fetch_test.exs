defmodule Egregoros.Federation.ThreadRepliesFetchTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Objects
  alias Egregoros.Users
  alias Egregoros.Workers.FetchThreadReplies

  test "thread replies worker discards jobs without a root_ap_id" do
    assert {:discard, :invalid_args} = FetchThreadReplies.perform(%Oban.Job{args: %{}})
  end

  test "thread replies worker fetches and ingests replies from an OrderedCollectionPage" do
    root_id = "https://remote.example/objects/root"
    replies_url = root_id <> "/replies"
    reply_id = "https://remote.example/objects/reply-1"

    {:ok, root} =
      Objects.create_object(%{
        ap_id: root_id,
        type: "Note",
        actor: "https://remote.example/users/alice",
        local: false,
        data: %{
          "id" => root_id,
          "type" => "Note",
          "attributedTo" => "https://remote.example/users/alice",
          "content" => "<p>Root</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "replies" => %{
            "id" => replies_url,
            "type" => "OrderedCollection"
          }
        }
      })

    expect(Egregoros.HTTP.Mock, :get, fn url, headers ->
      assert url == replies_url
      assert List.keyfind(headers, "signature", 0)
      assert List.keyfind(headers, "authorization", 0)

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => replies_url,
           "type" => "OrderedCollectionPage",
           "orderedItems" => [
             %{
               "id" => reply_id,
               "type" => "Note",
               "attributedTo" => "https://remote.example/users/bob",
               "content" => "<p>Reply</p>",
               "inReplyTo" => root_id,
               "to" => ["https://www.w3.org/ns/activitystreams#Public"],
               "cc" => []
             }
           ]
         },
         headers: []
       }}
    end)

    job =
      %Oban.Job{
        args: %{
          "root_ap_id" => root_id,
          "max_pages" => 1,
          "max_items" => 50
        }
      }

    assert :ok = FetchThreadReplies.perform(job)

    assert Objects.get_by_ap_id(reply_id)
    assert Enum.any?(Objects.thread_descendants(root), &(&1.ap_id == reply_id))
  end

  test "thread replies worker follows a collection's `first` page when needed" do
    root_id = "https://remote.example/objects/root-2"
    replies_url = root_id <> "/replies"
    first_page = replies_url <> "?page=true"
    reply_id = "https://remote.example/objects/reply-2"

    {:ok, root} =
      Objects.create_object(%{
        ap_id: root_id,
        type: "Note",
        actor: "https://remote.example/users/alice",
        local: false,
        data: %{
          "id" => root_id,
          "type" => "Note",
          "attributedTo" => "https://remote.example/users/alice",
          "content" => "<p>Root</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "replies" => replies_url
        }
      })

    expect(Egregoros.HTTP.Mock, :get, fn url, headers ->
      assert url == replies_url
      assert List.keyfind(headers, "signature", 0)
      assert List.keyfind(headers, "authorization", 0)

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => replies_url,
           "type" => "OrderedCollection",
           "first" => first_page
         },
         headers: []
       }}
    end)

    expect(Egregoros.HTTP.Mock, :get, fn url, headers ->
      assert url == first_page
      assert List.keyfind(headers, "signature", 0)
      assert List.keyfind(headers, "authorization", 0)

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => first_page,
           "type" => "OrderedCollectionPage",
           "orderedItems" => [
             %{
               "id" => reply_id,
               "type" => "Note",
               "attributedTo" => "https://remote.example/users/bob",
               "content" => "<p>Reply</p>",
               "inReplyTo" => root_id,
               "to" => ["https://www.w3.org/ns/activitystreams#Public"],
               "cc" => []
             }
           ]
         },
         headers: []
       }}
    end)

    job = %Oban.Job{args: %{"root_ap_id" => root_id, "max_pages" => 2, "max_items" => 50}}
    assert :ok = FetchThreadReplies.perform(job)

    assert Objects.get_by_ap_id(reply_id)
    assert Enum.any?(Objects.thread_descendants(root), &(&1.ap_id == reply_id))
  end

  test "thread replies worker fetches the root object when missing and exits when no replies are available" do
    actor_url = "https://remote.example/users/alice"

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        domain: "remote.example",
        ap_id: actor_url,
        inbox: actor_url <> "/inbox",
        outbox: actor_url <> "/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    create_id = "https://remote.example/activities/create/1"
    note_id = "https://remote.example/objects/root-no-replies"

    expect(Egregoros.HTTP.Mock, :get, fn url, headers ->
      assert url == create_id
      assert List.keyfind(headers, "signature", 0)
      assert List.keyfind(headers, "authorization", 0)

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => create_id,
           "type" => "Create",
           "actor" => actor_url,
           "object" => %{
             "id" => note_id,
             "type" => "Note",
             "attributedTo" => actor_url,
             "content" => "<p>Root</p>",
             "to" => ["https://www.w3.org/ns/activitystreams#Public"],
             "cc" => [],
             "replies" => ""
           }
         },
         headers: []
       }}
    end)

    job = %Oban.Job{args: %{"root_ap_id" => create_id}}
    assert :ok = FetchThreadReplies.perform(job)

    assert Objects.get_by_ap_id(create_id)
    assert Objects.get_by_ap_id(note_id)
  end

  test "thread replies worker ignores safe fetch errors for missing roots" do
    missing = "https://remote.example/objects/missing-root"

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == missing
      {:ok, %{status: 404, headers: []}}
    end)

    assert :ok = FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => missing}})

    assert :ok =
             FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => "javascript:alert(1)"}})

    id_mismatch = "https://remote.example/objects/mismatch-root"

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == id_mismatch

      {:ok,
       %{
         status: 200,
         body: %{"id" => "https://remote.example/objects/other", "type" => "Note"},
         headers: []
       }}
    end)

    assert :ok = FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => id_mismatch}})

    invalid_json = "https://remote.example/objects/invalid-json"

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == invalid_json
      {:ok, %{status: 200, body: "not json", headers: []}}
    end)

    assert :ok = FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => invalid_json}})
  end

  test "thread replies worker follows next pages without looping" do
    root_id = "https://remote.example/objects/root-loop"
    replies_url = root_id <> "/replies"
    reply_id = "https://remote.example/objects/reply-string"
    actor_url = "https://remote.example/users/alice"

    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        domain: "remote.example",
        ap_id: actor_url,
        inbox: actor_url <> "/inbox",
        outbox: actor_url <> "/outbox",
        public_key: "remote-key",
        private_key: nil,
        local: false
      })

    {:ok, root} =
      Objects.create_object(%{
        ap_id: root_id,
        type: "Note",
        actor: actor_url,
        local: false,
        data: %{
          "id" => root_id,
          "type" => "Note",
          "attributedTo" => actor_url,
          "content" => "<p>Root</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "replies" => replies_url
        }
      })

    body =
      Jason.encode!(%{
        "id" => replies_url,
        "type" => "OrderedCollectionPage",
        "orderedItems" => [reply_id],
        "next" => replies_url
      })

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == replies_url
      {:ok, %{status: 200, body: body, headers: []}}
    end)

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == reply_id

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => reply_id,
           "type" => "Note",
           "attributedTo" => actor_url,
           "content" => "<p>Reply</p>",
           "inReplyTo" => root_id,
           "to" => ["https://www.w3.org/ns/activitystreams#Public"],
           "cc" => []
         },
         headers: []
       }}
    end)

    job = %Oban.Job{args: %{"root_ap_id" => root_id, "max_pages" => "3", "max_items" => "bad"}}
    assert :ok = FetchThreadReplies.perform(job)

    assert Objects.get_by_ap_id(reply_id)
    assert Enum.any?(Objects.thread_descendants(root), &(&1.ap_id == reply_id))
  end

  test "thread replies worker tolerates invalid replies URLs and invalid JSON responses" do
    root_id = "https://remote.example/objects/root-invalid-replies"

    {:ok, _root} =
      Objects.create_object(%{
        ap_id: root_id,
        type: "Note",
        actor: "https://remote.example/users/alice",
        local: false,
        data: %{
          "id" => root_id,
          "type" => "Note",
          "attributedTo" => "https://remote.example/users/alice",
          "content" => "<p>Root</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "replies" => "javascript:alert(1)"
        }
      })

    assert :ok = FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => root_id}})

    json_root = "https://remote.example/objects/root-invalid-json"
    replies_url = json_root <> "/replies"

    {:ok, _root} =
      Objects.create_object(%{
        ap_id: json_root,
        type: "Note",
        actor: "https://remote.example/users/alice",
        local: false,
        data: %{"id" => json_root, "type" => "Note", "replies" => replies_url}
      })

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == replies_url
      {:ok, %{status: 200, body: "not json", headers: []}}
    end)

    assert :ok = FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => json_root}})
  end

  test "thread replies worker returns an error for non-2xx replies fetches" do
    root_id = "https://remote.example/objects/root-error"
    replies_url = root_id <> "/replies"

    {:ok, _root} =
      Objects.create_object(%{
        ap_id: root_id,
        type: "Note",
        actor: "https://remote.example/users/alice",
        local: false,
        data: %{
          "id" => root_id,
          "type" => "Note",
          "attributedTo" => "https://remote.example/users/alice",
          "content" => "<p>Root</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "replies" => replies_url
        }
      })

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == replies_url
      {:ok, %{status: 500, body: %{}, headers: []}}
    end)

    assert {:error, :replies_fetch_failed} =
             FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => root_id}})
  end

  test "thread replies worker ignores http status responses without bodies" do
    root_id = "https://remote.example/objects/root-http-status"
    replies_url = root_id <> "/replies"

    {:ok, _root} =
      Objects.create_object(%{
        ap_id: root_id,
        type: "Note",
        actor: "https://remote.example/users/alice",
        local: false,
        data: %{"id" => root_id, "type" => "Note", "replies" => replies_url}
      })

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == replies_url
      {:ok, %{status: 404, headers: []}}
    end)

    assert :ok = FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => root_id}})
  end

  test "thread replies worker ignores Create roots without embedded notes when refetching fails" do
    create_id = "https://remote.example/activities/create/orphan"

    {:ok, _create} =
      Objects.create_object(%{
        ap_id: create_id,
        type: "Create",
        actor: "https://remote.example/users/alice",
        object: "https://remote.example/objects/missing-note",
        local: false,
        data: %{"id" => create_id, "type" => "Create"}
      })

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == create_id
      {:ok, %{status: 404, headers: []}}
    end)

    assert :ok = FetchThreadReplies.perform(%Oban.Job{args: %{"root_ap_id" => create_id}})
  end
end
