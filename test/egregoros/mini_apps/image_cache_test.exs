defmodule Egregoros.MiniApps.ImageCacheTest do
  use ExUnit.Case, async: true

  alias Egregoros.MiniApps.ImageCache

  test "caches successful sanitized results" do
    cache = start_cache()
    key = {:card, "resolution", "https://app.example/card.png"}
    result = {:ok, %{body: "safe-webp", content_type: "image/webp"}}

    assert ^result =
             ImageCache.fetch(
               key,
               fn ->
                 send(self(), :loaded)
                 result
               end,
               server: cache
             )

    assert_receive :loaded

    assert ^result =
             ImageCache.fetch(
               key,
               fn ->
                 flunk("a cached image must not be loaded again")
               end,
               server: cache
             )
  end

  test "coalesces concurrent loads for the same resolution" do
    cache = start_cache()
    task_supervisor = start_task_supervisor()
    parent = self()
    key = {:card, "resolution", "https://app.example/card.png"}
    result = {:ok, %{body: "safe-webp", content_type: "image/webp"}}

    first =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ImageCache.fetch(
          key,
          fn ->
            send(parent, {:loader_started, self()})

            receive do
              :finish_load -> result
            end
          end,
          server: cache
        )
      end)

    assert_receive {:loader_started, loader_pid}

    second =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ImageCache.fetch(
          key,
          fn ->
            send(parent, :duplicate_loader_started)
            result
          end,
          server: cache
        )
      end)

    refute_receive :duplicate_loader_started, 50
    send(loader_pid, :finish_load)

    assert Task.await(first) == result
    assert Task.await(second) == result
  end

  test "does not cache failures" do
    cache = start_cache()
    key = {:card, "resolution", "https://app.example/card.png"}

    for attempt <- 1..2 do
      assert {:error, {:fetch, :timeout}} =
               ImageCache.fetch(
                 key,
                 fn ->
                   send(self(), {:loaded, attempt})
                   {:error, {:fetch, :timeout}}
                 end,
                 server: cache
               )

      assert_receive {:loaded, ^attempt}
    end
  end

  test "does not retain a sanitized result larger than the byte budget" do
    cache = start_cache(max_bytes: 4)
    key = {:card, "resolution", "https://app.example/card.png"}
    result = {:ok, %{body: "12345", content_type: "image/webp"}}

    for attempt <- 1..2 do
      assert ^result =
               ImageCache.fetch(
                 key,
                 fn ->
                   send(self(), {:loaded, attempt})
                   result
                 end,
                 server: cache
               )

      assert_receive {:loaded, ^attempt}
    end
  end

  test "evicts the least recently used result at the entry limit" do
    cache = start_cache(max_entries: 1)
    first_key = {:card, "first", "https://app.example/first.png"}
    second_key = {:card, "second", "https://app.example/second.png"}

    assert {:ok, %{body: "first"}} =
             ImageCache.fetch(first_key, fn -> sanitized("first") end, server: cache)

    assert {:ok, %{body: "second"}} =
             ImageCache.fetch(second_key, fn -> sanitized("second") end, server: cache)

    assert {:ok, %{body: "first-again"}} =
             ImageCache.fetch(
               first_key,
               fn ->
                 send(self(), :first_reloaded)
                 sanitized("first-again")
               end,
               server: cache
             )

    assert_receive :first_reloaded
  end

  test "clear removes retained sanitized results" do
    cache = start_cache()
    key = {:card, "resolution", "https://app.example/card.png"}

    assert {:ok, %{body: "first"}} =
             ImageCache.fetch(key, fn -> sanitized("first") end, server: cache)

    assert :ok = ImageCache.clear(cache)

    assert {:ok, %{body: "second"}} =
             ImageCache.fetch(
               key,
               fn ->
                 send(self(), :reloaded)
                 sanitized("second")
               end,
               server: cache
             )

    assert_receive :reloaded
  end

  defp start_cache(options \\ []) do
    name = {:global, {__MODULE__, make_ref()}}

    start_supervised!(
      {ImageCache,
       [
         name: name,
         ttl_ms: 60_000,
         max_entries: Keyword.get(options, :max_entries, 4),
         max_bytes: Keyword.get(options, :max_bytes, 1_024),
         cleanup_interval_ms: 60_000
       ]}
    )

    name
  end

  defp start_task_supervisor do
    name = {:global, {__MODULE__.TaskSupervisor, make_ref()}}
    start_supervised!({Task.Supervisor, name: name})
    name
  end

  defp sanitized(body), do: {:ok, %{body: body, content_type: "image/webp"}}
end
