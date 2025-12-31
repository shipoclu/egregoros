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

  test "allow?/4 resets counts when the time window changes" do
    key = "key-" <> Ecto.UUID.generate()
    assert :ok == ETS.allow?(:inbox, key, 1, 1)
    Process.sleep(2)
    assert :ok == ETS.allow?(:inbox, key, 1, 1)
  end

  test "cleanup removes entries older than the ttl" do
    pid = Process.whereis(ETS)
    assert is_pid(pid)

    %{entry_ttl_ms: ttl_ms} = :sys.get_state(ETS)
    threshold_ms = System.monotonic_time(:millisecond) - ttl_ms

    ets_key = {:inbox, "cleanup-" <> Ecto.UUID.generate(), 60_000}
    :ets.insert(@table, {ets_key, 0, 1, threshold_ms - 1})
    assert :ets.lookup(@table, ets_key) != []

    send(pid, :cleanup)
    _state = :sys.get_state(ETS)

    assert :ets.lookup(@table, ets_key) == []
  end
end
