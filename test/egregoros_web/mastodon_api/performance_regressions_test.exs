defmodule EgregorosWeb.MastodonAPI.PerformanceRegressionsTest do
  use EgregorosWeb.ConnCase, async: false

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.Users

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

  test "GET /api/v1/accounts/:id/followers batches follower rendering queries", %{conn: conn} do
    {:ok, target} = Users.create_local_user("target")

    followers =
      for idx <- 1..10 do
        {:ok, follower} = Users.create_local_user("follower#{idx}")

        assert {:ok, _follow} =
                 Pipeline.ingest(
                   %{
                     "id" => "https://example.com/activities/follow/#{idx}",
                     "type" => "Follow",
                     "actor" => follower.ap_id,
                     "object" => target.ap_id
                   },
                   local: true
                 )

        follower
      end

    {conn, queries} =
      capture_repo_queries(fn ->
        get(conn, "/api/v1/accounts/#{target.id}/followers")
      end)

    response = json_response(conn, 200)

    for follower <- followers do
      assert Enum.any?(response, &(&1["id"] == follower.id))
    end

    assert length(queries) <= 12
  end

  test "GET /api/v1/accounts/:id/following batches followed rendering queries", %{conn: conn} do
    {:ok, follower} = Users.create_local_user("follower")

    targets =
      for idx <- 1..10 do
        {:ok, target} = Users.create_local_user("target#{idx}")

        assert {:ok, _follow} =
                 Pipeline.ingest(
                   %{
                     "id" => "https://example.com/activities/following/#{idx}",
                     "type" => "Follow",
                     "actor" => follower.ap_id,
                     "object" => target.ap_id
                   },
                   local: true
                 )

        target
      end

    {conn, queries} =
      capture_repo_queries(fn ->
        get(conn, "/api/v1/accounts/#{follower.id}/following")
      end)

    response = json_response(conn, 200)

    for target <- targets do
      assert Enum.any?(response, &(&1["id"] == target.id))
    end

    assert length(queries) <= 12
  end

  test "GET /api/v1/statuses/:id/favourited_by batches liker rendering queries", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, note} =
      Objects.create_object(%{
        ap_id: "https://example.com/objects/note-1",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://example.com/objects/note-1",
          "type" => "Note",
          "actor" => alice.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "content" => "hi"
        }
      })

    likers =
      for idx <- 1..10 do
        {:ok, liker} = Users.create_local_user("liker#{idx}")

        assert {:ok, _} =
                 Relationships.upsert_relationship(%{
                   type: "Like",
                   actor: liker.ap_id,
                   object: note.ap_id,
                   activity_ap_id: "https://example.com/activities/like/#{idx}"
                 })

        liker
      end

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    {conn, queries} =
      capture_repo_queries(fn ->
        get(conn, "/api/v1/statuses/#{note.id}/favourited_by")
      end)

    response = json_response(conn, 200)

    for liker <- likers do
      assert Enum.any?(response, &(&1["id"] == liker.id))
    end

    assert length(queries) <= 12
  end

  test "GET /api/v1/statuses/:id/reblogged_by batches reblogger rendering queries", %{conn: conn} do
    {:ok, alice} = Users.create_local_user("alice")

    {:ok, note} =
      Objects.create_object(%{
        ap_id: "https://example.com/objects/note-2",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://example.com/objects/note-2",
          "type" => "Note",
          "actor" => alice.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "content" => "hi"
        }
      })

    rebloggers =
      for idx <- 1..10 do
        {:ok, reblogger} = Users.create_local_user("reblogger#{idx}")

        assert {:ok, _} =
                 Relationships.upsert_relationship(%{
                   type: "Announce",
                   actor: reblogger.ap_id,
                   object: note.ap_id,
                   activity_ap_id: "https://example.com/activities/announce/#{idx}"
                 })

        reblogger
      end

    Egregoros.Auth.Mock
    |> expect(:current_user, fn _conn -> {:ok, alice} end)

    {conn, queries} =
      capture_repo_queries(fn ->
        get(conn, "/api/v1/statuses/#{note.id}/reblogged_by")
      end)

    response = json_response(conn, 200)

    for reblogger <- rebloggers do
      assert Enum.any?(response, &(&1["id"] == reblogger.id))
    end

    assert length(queries) <= 12
  end
end
