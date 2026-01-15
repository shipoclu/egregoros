defmodule Egregoros.PerformanceRegressionsTest do
  use Egregoros.DataCase, async: false

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Users
  alias EgregorosWeb.MastodonAPI.StatusRenderer
  alias EgregorosWeb.ViewModels.Status, as: StatusVM

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:egregoros, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:repo_query, metadata})
      end,
      nil
    )

    try do
      result = fun.()
      {result, flush_repo_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp flush_repo_queries(acc) do
    receive do
      {:repo_query, metadata} -> flush_repo_queries([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "home timeline queries do not load follows into memory" do
    {:ok, alice} = Users.create_local_user("alice")

    bob_ap_id = "https://remote.example/users/bob"

    assert {:ok, _follow} =
             Pipeline.ingest(
               %{
                 "id" => "https://local.example/activities/follow/1",
                 "type" => "Follow",
                 "actor" => alice.ap_id,
                 "object" => bob_ap_id
               },
               local: true
             )

    assert {:ok, _note} =
             Objects.create_object(%{
               ap_id: "https://remote.example/objects/bob-1",
               type: "Note",
               actor: bob_ap_id,
               object: nil,
               data: %{
                 "id" => "https://remote.example/objects/bob-1",
                 "type" => "Note",
                 "actor" => bob_ap_id,
                 "to" => [bob_ap_id <> "/followers"],
                 "content" => "hello"
               },
               local: false
             })

    {_notes, notes_queries} =
      capture_repo_queries(fn -> Objects.list_home_notes(alice.ap_id, limit: 20) end)

    # Before optimization we ran a separate query to load all follow relationships, then another
    # query for the timeline. We want a single SQL query with a follow subquery instead.
    assert length(notes_queries) == 1

    {_statuses, statuses_queries} =
      capture_repo_queries(fn -> Objects.list_home_statuses(alice.ap_id, limit: 20) end)

    assert length(statuses_queries) == 1
  end

  test "status rendering batches relationship queries" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, carol} = Users.create_local_user("carol")

    {:ok, note_1} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/1",
        type: "Note",
        actor: bob.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/1",
          "type" => "Note",
          "actor" => bob.ap_id,
          "content" => "hello"
        }
      })

    {:ok, note_2} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/2",
        type: "Note",
        actor: carol.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/2",
          "type" => "Note",
          "actor" => carol.ap_id,
          "content" => "hello"
        }
      })

    {:ok, note_3} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/3",
        type: "Note",
        actor: carol.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/3",
          "type" => "Note",
          "actor" => carol.ap_id,
          "content" => "hello"
        }
      })

    {rendered, queries} =
      capture_repo_queries(fn ->
        StatusRenderer.render_statuses([note_1, note_2, note_3], alice)
      end)

    # Before batching, rendering each status issues multiple per-status count queries (likes, reblogs,
    # emoji reactions, plus account counts), which scales linearly with the number of statuses.
    assert length(queries) <= 15
    assert length(rendered) == 3
  end

  test "status view model decoration batches relationship queries" do
    {:ok, alice} = Users.create_local_user("alice")
    {:ok, bob} = Users.create_local_user("bob")
    {:ok, carol} = Users.create_local_user("carol")

    {:ok, note_1} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/1",
        type: "Note",
        actor: bob.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/1",
          "type" => "Note",
          "actor" => bob.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "content" => "hello"
        }
      })

    {:ok, note_2} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/2",
        type: "Note",
        actor: carol.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/2",
          "type" => "Note",
          "actor" => carol.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "content" => "hello"
        }
      })

    {:ok, announce} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/announce-1",
        type: "Announce",
        actor: alice.ap_id,
        object: note_1.ap_id,
        local: false,
        data: %{
          "id" => "https://remote.example/objects/announce-1",
          "type" => "Announce",
          "actor" => alice.ap_id,
          "object" => note_1.ap_id
        }
      })

    {decorated, queries} =
      capture_repo_queries(fn ->
        StatusVM.decorate_many([note_1, announce, note_2], alice)
      end)

    # Before batching, decoration does per-item user lookups, relationship counts, and per-emoji
    # reacted? checks, which scales linearly with the number of statuses.
    assert length(queries) <= 10
    assert length(decorated) == 3
    assert Enum.any?(decorated, &Map.has_key?(&1, :reposted_by))
  end

  test "critical composite indexes exist" do
    result =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename IN ('objects', 'relationships', 'users')",
        []
      )

    index_names =
      result.rows
      |> Enum.map(&List.first/1)
      |> MapSet.new()

    for name <- [
          "objects_type_id_index",
          "objects_actor_type_id_index",
          "relationships_object_type_index",
          "users_nickname_trgm_index",
          "users_name_trgm_index",
          "users_domain_trgm_index"
        ] do
      assert MapSet.member?(index_names, name)
    end
  end
end
