defmodule Egregoros.RateLimiter.ETSTest do
  use ExUnit.Case, async: false

  alias Egregoros.RateLimiter.ETS

  @table :egregoros_rate_limiter

  test "allow?/4 returns :ok for empty keys and invalid limits" do
    assert is_pid(Process.whereis(ETS))
    assert :ok == ETS.allow?(:inbox, " ", 1, 1_000)
    assert :ok == ETS.allow?(:inbox, "", 1, 1_000)
    assert :ok == ETS.allow?(:inbox, "key", 0, 1_000)
    assert :ok == ETS.allow?(:inbox, "key", 1, 0)
    assert :ok == ETS.allow?("not-atom", "key", 1, 1_000)
  end

  test "allow?/4 rate limits when exceeding the limit within the same window" do
    key = "key-" <> Ecto.UUID.generate()

    assert :ok == ETS.allow?(:inbox, key, 2, 60_000)
    assert :ok == ETS.allow?(:inbox, key, 2, 60_000)
    assert {:error, :rate_limited} == ETS.allow?(:inbox, key, 2, 60_000)
  end

  test "allow?/4 atomically admits no more than the limit under concurrency" do
    key = "concurrent-" <> Ecto.UUID.generate()

    results =
      1..200
      |> Task.async_stream(
        fn _ -> ETS.allow?(:login, key, 25, 60_000) end,
        max_concurrency: 40,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 25
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 175
  end

  test "allow?/4 resets counts when the time window changes" do
    key = "key-" <> Ecto.UUID.generate()

    now_ms = System.monotonic_time(:millisecond)
    current_window_id = div(now_ms, 1)

    :ets.insert(@table, {{:inbox, key, 1, current_window_id - 1}, 1, now_ms})

    assert :ok == ETS.allow?(:inbox, key, 1, 1)
  end

  test "cleanup removes entries older than the ttl" do
    pid = Process.whereis(ETS)
    assert is_pid(pid)

    %{entry_ttl_ms: ttl_ms} = :sys.get_state(ETS)
    threshold_ms = System.monotonic_time(:millisecond) - ttl_ms

    ets_key = {:inbox, "cleanup-" <> Ecto.UUID.generate(), 60_000, 0}
    :ets.insert(@table, {ets_key, 1, threshold_ms - 1})
    assert :ets.lookup(@table, ets_key) != []

    send(pid, :cleanup)
    _state = :sys.get_state(ETS)

    assert :ets.lookup(@table, ets_key) == []
  end
end
