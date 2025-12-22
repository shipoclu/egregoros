defmodule PleromaRedux.Bench.Runner do
  @moduledoc false

  alias PleromaRedux.Bench.Stats

  def measure(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    warmup = opts |> Keyword.get(:warmup, 2) |> normalize_nonneg_int()
    iterations = opts |> Keyword.get(:iterations, 10) |> normalize_pos_int()
    now_us = Keyword.get(opts, :now_us, fn -> System.monotonic_time(:microsecond) end)
    track_queries? = Keyword.get(opts, :track_queries?, true)

    now_us =
      case now_us do
        now when is_function(now, 0) -> now
        _ -> fn -> System.monotonic_time(:microsecond) end
      end

    {durations, query_counts, query_total_us} =
      if track_queries? do
        with_repo_query_tracking(fn ->
          run_iterations(fun, now_us, warmup, iterations, true)
        end)
      else
        run_iterations(fun, now_us, warmup, iterations, false)
      end

    result = %{
      durations_us: durations,
      stats: Stats.summary(durations)
    }

    if track_queries? do
      Map.merge(result, %{
        queries: %{
          count: Stats.summary(query_counts),
          total_time_us: Stats.summary(query_total_us)
        }
      })
    else
      result
    end
  end

  defp run_iterations(fun, now_us, warmup, iterations, track_queries?) do
    {durations, query_counts, query_total_us} =
      1..(warmup + iterations)
      |> Enum.reduce({[], [], []}, fn idx, {durations, query_counts, query_total_us} ->
        if track_queries? do
          Process.put(:bench_query_count, 0)
          Process.put(:bench_query_total_us, 0)
        end

        start = now_us.()
        _ = fun.()
        stop = now_us.()
        duration = stop - start

        if idx <= warmup do
          {durations, query_counts, query_total_us}
        else
          if track_queries? do
            count = Process.get(:bench_query_count, 0)
            total_us = Process.get(:bench_query_total_us, 0)
            {[duration | durations], [count | query_counts], [total_us | query_total_us]}
          else
            {[duration | durations], query_counts, query_total_us}
          end
        end
      end)

    {Enum.reverse(durations), Enum.reverse(query_counts), Enum.reverse(query_total_us)}
  end

  defp with_repo_query_tracking(fun) when is_function(fun, 0) do
    handler_id = {:pleroma_redux, :bench, make_ref()}
    event = [:pleroma_redux, :repo, :query]

    :telemetry.attach(
      handler_id,
      event,
      &__MODULE__.handle_repo_query/4,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  def handle_repo_query(_event_name, measurements, _metadata, _config) do
    Process.put(:bench_query_count, Process.get(:bench_query_count, 0) + 1)

    total_us =
      case Map.get(measurements, :total_time) do
        time when is_integer(time) ->
          System.convert_time_unit(time, :native, :microsecond)

        _ ->
          0
      end

    Process.put(:bench_query_total_us, Process.get(:bench_query_total_us, 0) + total_us)
  end

  defp normalize_nonneg_int(value) when is_integer(value) and value >= 0, do: value
  defp normalize_nonneg_int(_), do: 0

  defp normalize_pos_int(value) when is_integer(value) and value > 0, do: value
  defp normalize_pos_int(_), do: 1
end
