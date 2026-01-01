defmodule Egregoros.Federation.FetchThreadAncestorsTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Objects
  alias Egregoros.Timeline
  alias Egregoros.Workers.FetchThreadAncestors

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  test "perform/1 discards jobs without a start_ap_id" do
    assert {:discard, :invalid_args} = FetchThreadAncestors.perform(%Oban.Job{args: %{}})
  end

  test "perform/1 normalizes Create wrapper objects to their embedded Note for ancestor fetching" do
    suffix = Ecto.UUID.generate()

    start_ap_id = "https://remote.example/activities/create/" <> suffix
    note_ap_id = "https://remote.example/objects/note/" <> suffix
    parent_id = "https://remote.example/objects/parent/" <> suffix
    actor = "https://remote.example/users/alice-" <> suffix

    assert {:ok, _note} =
             Objects.create_object(%{
               ap_id: note_ap_id,
               type: "Note",
               actor: actor,
               local: false,
               data: %{
                 "id" => note_ap_id,
                 "type" => "Note",
                 "attributedTo" => actor,
                 "inReplyTo" => parent_id,
                 "to" => [@as_public],
                 "content" => "hello"
               }
             })

    assert {:ok, _create} =
             Objects.create_object(%{
               ap_id: start_ap_id,
               type: "Create",
               actor: actor,
               object: note_ap_id,
               local: false,
               data: %{
                 "id" => start_ap_id,
                 "type" => "Create",
                 "actor" => actor,
                 "object" => note_ap_id
               }
             })

    assert Objects.get_by_ap_id(parent_id) == nil

    expect(Egregoros.HTTP.Mock, :get, fn url, headers ->
      assert url == parent_id
      assert List.keyfind(headers, "signature", 0)
      assert List.keyfind(headers, "authorization", 0)

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => parent_id,
           "type" => "Note",
           "attributedTo" => actor,
           "to" => [@as_public],
           "content" => "parent"
         },
         headers: []
       }}
    end)

    assert :ok = FetchThreadAncestors.perform(%Oban.Job{args: %{"start_ap_id" => start_ap_id}})
    assert Objects.get_by_ap_id(parent_id)
  end

  test "perform/1 clamps max_depth parsed from strings and stops fetching when exhausted" do
    suffix = Ecto.UUID.generate()

    reply_id = "https://remote.example/objects/reply-depth/" <> suffix
    parent_id = "https://remote.example/objects/parent-depth/" <> suffix
    grandparent_id = "https://remote.example/objects/grandparent-depth/" <> suffix
    actor = "https://remote.example/users/alice-" <> suffix

    assert {:ok, _reply} =
             Objects.create_object(%{
               ap_id: reply_id,
               type: "Note",
               actor: actor,
               local: false,
               data: %{
                 "id" => reply_id,
                 "type" => "Note",
                 "attributedTo" => actor,
                 "inReplyTo" => parent_id,
                 "to" => [@as_public],
                 "content" => "reply"
               }
             })

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == parent_id

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => parent_id,
           "type" => "Note",
           "attributedTo" => actor,
           "inReplyTo" => grandparent_id,
           "to" => [@as_public],
           "content" => "parent"
         },
         headers: []
       }}
    end)

    assert :ok =
             FetchThreadAncestors.perform(%Oban.Job{
               args: %{"start_ap_id" => reply_id, "max_depth" => "0"}
             })

    assert Objects.get_by_ap_id(parent_id)
    assert Objects.get_by_ap_id(grandparent_id) == nil
  end

  test "perform/1 fetches missing start objects and broadcasts pending announces" do
    suffix = Ecto.UUID.generate()

    start_ap_id = "https://remote.example/objects/missing-start/" <> suffix
    parent_id = "https://remote.example/objects/missing-parent/" <> suffix
    actor = "https://remote.example/users/alice-" <> suffix

    Timeline.subscribe_public()

    assert {:ok, announce} =
             Objects.create_object(%{
               ap_id: "https://remote.example/activities/announce/" <> suffix,
               type: "Announce",
               actor: actor,
               object: start_ap_id,
               local: false,
               data: %{
                 "id" => "https://remote.example/activities/announce/" <> suffix,
                 "type" => "Announce",
                 "actor" => actor,
                 "object" => start_ap_id,
                 "to" => [@as_public]
               }
             })

    announce_ap_id = announce.ap_id

    assert Objects.get_by_ap_id(start_ap_id) == nil

    expect(Egregoros.HTTP.Mock, :get, 2, fn url, _headers ->
      case url do
        ^start_ap_id ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => start_ap_id,
               "type" => "Note",
               "attributedTo" => actor,
               "inReplyTo" => parent_id,
               "to" => [@as_public],
               "content" => "start"
             },
             headers: []
           }}

        ^parent_id ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => parent_id,
               "type" => "Note",
               "attributedTo" => actor,
               "to" => [@as_public],
               "content" => "parent"
             },
             headers: []
           }}
      end
    end)

    assert :ok = FetchThreadAncestors.perform(%Oban.Job{args: %{"start_ap_id" => start_ap_id}})

    assert Objects.get_by_ap_id(start_ap_id)
    assert Objects.get_by_ap_id(parent_id)
    assert_receive {:post_created, %{ap_id: ^announce_ap_id}}
  end

  test "perform/1 ignores forbidden or missing parents without failing the job" do
    suffix = Ecto.UUID.generate()

    reply_id = "https://remote.example/objects/reply-forbidden/" <> suffix
    parent_id = "https://remote.example/objects/parent-forbidden/" <> suffix
    actor = "https://remote.example/users/alice-" <> suffix

    assert {:ok, _reply} =
             Objects.create_object(%{
               ap_id: reply_id,
               type: "Note",
               actor: actor,
               local: false,
               data: %{
                 "id" => reply_id,
                 "type" => "Note",
                 "attributedTo" => actor,
                 "inReplyTo" => parent_id,
                 "to" => [@as_public],
                 "content" => "reply"
               }
             })

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == parent_id
      {:ok, %{status: 404, body: "", headers: []}}
    end)

    assert :ok = FetchThreadAncestors.perform(%Oban.Job{args: %{"start_ap_id" => reply_id}})
    assert Objects.get_by_ap_id(parent_id) == nil
  end
end
