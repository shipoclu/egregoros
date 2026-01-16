defmodule Egregoros.PerformanceBudgetsTest do
  use Egregoros.DataCase, async: false

  alias Egregoros.Objects
  alias Egregoros.Relationships
  alias Egregoros.Users

  @moduletag :performance_budget

  @query_budget 1

  defp capture_repo_queries(fun, filter \\ fn _metadata -> true end)
       when is_function(fun, 0) and is_function(filter, 1) do
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:egregoros, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if filter.(metadata) do
          send(parent, {:repo_query, metadata})
        end
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

  defp timeline_query?(metadata, feature, name) when is_map(metadata) and is_atom(name) do
    options = metadata |> Map.get(:options) |> List.wrap()
    Keyword.get(options, :feature) == feature and Keyword.get(options, :name) == name
  end

  test "list_home_statuses stays within query budget (no follows)" do
    {:ok, alice} = Users.create_local_user("budget-alice")

    {_result, queries} =
      capture_repo_queries(
        fn -> Objects.list_home_statuses(alice.ap_id, limit: 20) end,
        fn metadata -> timeline_query?(metadata, :timeline, :list_home_statuses) end
      )

    assert length(queries) == @query_budget
  end

  test "list_home_statuses stays within query budget (dormant follows)" do
    {:ok, alice} = Users.create_local_user("budget-dormant")

    remotes =
      for idx <- 1..20 do
        {:ok, remote} =
          Users.create_user(%{
            nickname: "budget-remote-#{idx}",
            domain: "remote.example",
            ap_id: "https://remote.example/users/budget-remote-#{idx}",
            inbox: "https://remote.example/users/budget-remote-#{idx}/inbox",
            outbox: "https://remote.example/users/budget-remote-#{idx}/outbox",
            public_key: "remote-key",
            private_key: nil,
            local: false
          })

        remote
      end

    for remote <- remotes do
      assert {:ok, _follow} =
               Relationships.upsert_relationship(%{
                 type: "Follow",
                 actor: alice.ap_id,
                 object: remote.ap_id
               })
    end

    {_result, queries} =
      capture_repo_queries(
        fn -> Objects.list_home_statuses(alice.ap_id, limit: 20) end,
        fn metadata -> timeline_query?(metadata, :timeline, :list_home_statuses) end
      )

    assert length(queries) == @query_budget
  end

  test "list_public_statuses_by_hashtag stays within query budget (only_media=true)" do
    {:ok, alice} = Users.create_local_user("budget-hashtag")

    {:ok, _note} =
      Objects.create_object(%{
        ap_id: "https://local.example/objects/budget-hashtag-note-1",
        type: "Note",
        actor: alice.ap_id,
        has_media: true,
        local: true,
        data: %{
          "id" => "https://local.example/objects/budget-hashtag-note-1",
          "type" => "Note",
          "actor" => alice.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "tag" => [%{"type" => "Hashtag", "name" => "#bench"}],
          "content" => "hello #bench"
        }
      })

    {_result, queries} =
      capture_repo_queries(
        fn -> Objects.list_public_statuses_by_hashtag("bench", limit: 20, only_media: true) end,
        fn metadata -> timeline_query?(metadata, :timeline, :list_public_statuses_by_hashtag) end
      )

    assert length(queries) == @query_budget
  end

  test "count_note_replies_by_parent_ap_ids stays within query budget" do
    {:ok, alice} = Users.create_local_user("budget-replies")

    {:ok, parent_1} =
      Objects.create_object(%{
        ap_id: "https://local.example/objects/budget-parent-1",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://local.example/objects/budget-parent-1",
          "type" => "Note",
          "actor" => alice.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "content" => "parent 1"
        }
      })

    {:ok, parent_2} =
      Objects.create_object(%{
        ap_id: "https://local.example/objects/budget-parent-2",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://local.example/objects/budget-parent-2",
          "type" => "Note",
          "actor" => alice.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "content" => "parent 2"
        }
      })

    for idx <- 1..3 do
      {:ok, _reply} =
        Objects.create_object(%{
          ap_id: "https://local.example/objects/budget-reply-1-#{idx}",
          type: "Note",
          actor: alice.ap_id,
          local: true,
          in_reply_to_ap_id: parent_1.ap_id,
          data: %{
            "id" => "https://local.example/objects/budget-reply-1-#{idx}",
            "type" => "Note",
            "actor" => alice.ap_id,
            "to" => ["https://www.w3.org/ns/activitystreams#Public"],
            "inReplyTo" => parent_1.ap_id,
            "content" => "reply 1 #{idx}"
          }
        })
    end

    for idx <- 1..2 do
      {:ok, _reply} =
        Objects.create_object(%{
          ap_id: "https://local.example/objects/budget-reply-2-#{idx}",
          type: "Note",
          actor: alice.ap_id,
          local: true,
          in_reply_to_ap_id: parent_2.ap_id,
          data: %{
            "id" => "https://local.example/objects/budget-reply-2-#{idx}",
            "type" => "Note",
            "actor" => alice.ap_id,
            "to" => ["https://www.w3.org/ns/activitystreams#Public"],
            "inReplyTo" => parent_2.ap_id,
            "content" => "reply 2 #{idx}"
          }
        })
    end

    {counts, queries} =
      capture_repo_queries(fn ->
        Objects.count_note_replies_by_parent_ap_ids([parent_1.ap_id, parent_2.ap_id])
      end)

    assert length(queries) == @query_budget
    assert counts[parent_1.ap_id] == 3
    assert counts[parent_2.ap_id] == 2
  end
end
