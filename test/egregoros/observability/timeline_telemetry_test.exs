defmodule Egregoros.Observability.TimelineTelemetryTest do
  use Egregoros.DataCase, async: false

  alias Egregoros.Objects
  alias Egregoros.Users

  defp capture_repo_queries(fun, filter) when is_function(fun, 0) and is_function(filter, 1) do
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

  defp capture_telemetry_events(event, fun, filter)
       when is_list(event) and is_function(fun, 0) and is_function(filter, 2) do
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      event,
      fn _event, measurements, metadata, _config ->
        if filter.(measurements, metadata) do
          send(parent, {:telemetry_event, measurements, metadata})
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, flush_telemetry_events([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp flush_telemetry_events(acc) do
    receive do
      {:telemetry_event, measurements, metadata} ->
        flush_telemetry_events([{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "public timeline query is tagged via repo telemetry options" do
    {:ok, alice} = Users.create_local_user("telemetry-alice")

    {:ok, _note} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/telemetry-note-1",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://remote.example/objects/telemetry-note-1",
          "type" => "Note",
          "actor" => alice.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "content" => "hello"
        }
      })

    {_objects, queries} =
      capture_repo_queries(
        fn -> Objects.list_public_statuses(limit: 20) end,
        fn metadata ->
          options = metadata |> Map.get(:options) |> List.wrap()

          Keyword.get(options, :feature) == :timeline and
            Keyword.get(options, :name) == :list_public_statuses
        end
      )

    assert length(queries) == 1
  end

  test "public timeline emits a high-level telemetry span" do
    {:ok, alice} = Users.create_local_user("telemetry-bob")

    {:ok, _note} =
      Objects.create_object(%{
        ap_id: "https://remote.example/objects/telemetry-note-2",
        type: "Note",
        actor: alice.ap_id,
        local: true,
        data: %{
          "id" => "https://remote.example/objects/telemetry-note-2",
          "type" => "Note",
          "actor" => alice.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "content" => "hello"
        }
      })

    {_result, events} =
      capture_telemetry_events(
        [:egregoros, :timeline, :read, :stop],
        fn -> Objects.list_public_statuses(limit: 20) end,
        fn _measurements, metadata ->
          Map.get(metadata, :name) == :list_public_statuses
        end
      )

    assert length(events) == 1
  end
end
