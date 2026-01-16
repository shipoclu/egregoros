defmodule Mix.Tasks.Egregoros.Bench.Explain do
  use Mix.Task

  @shortdoc "Run EXPLAIN (ANALYZE, BUFFERS) for benchmark cases"

  @moduledoc """
  Runs `EXPLAIN` for the selected benchmark case(s), capturing the executed SQL via Repo telemetry.

  Recommended usage (after `mix egregoros.bench.seed`):

      MIX_ENV=bench mix egregoros.bench.explain --filter timeline.home.edge_nofollows

  Options:

    * `--filter` (substring; optional)
    * `--out` (default: `tmp/bench_explain`)
    * `--format` (`text` or `json`; default: `text`)
    * `--[no-]print` (default: print)
  """

  @switches [filter: :string, out: :string, format: :string, print: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    filter = opts |> Keyword.get(:filter) |> normalize_filter()
    out_dir = opts |> Keyword.get(:out, "tmp/bench_explain") |> normalize_out_dir()
    format = opts |> Keyword.get(:format, "text") |> normalize_format()
    print? = Keyword.get(opts, :print, true) == true

    cases =
      Egregoros.Bench.Suite.default_cases()
      |> maybe_filter_cases(filter)

    File.mkdir_p!(out_dir)

    Enum.each(cases, fn %{name: name, fun: fun} ->
      explain_case(name, fun, out_dir, format, print?)
    end)
  end

  defp explain_case(name, fun, out_dir, format, print?)
       when is_binary(name) and is_function(fun, 0) and is_binary(out_dir) and
              format in [:text, :json] and
              is_boolean(print?) do
    {_, captured} = capture_repo_queries(fun)

    case pick_query_for_explain(captured) do
      nil ->
        Mix.shell().info("Case: #{name} (skipped; no explainable SQL captured)")

      %{query: query, params: params, options: options} = picked ->
        explain_result = run_explain(query, params, format)
        file_path = write_output(out_dir, name, picked, explain_result, format)

        Mix.shell().info("Case: #{name}")
        Mix.shell().info("EXPLAIN (ANALYZE, BUFFERS) -> #{file_path}")

        if print? do
          Mix.shell().info(explain_result)
        end

        if options do
          Mix.shell().info("Telemetry options: #{inspect(options)}")
        end

        Mix.shell().info("")
    end
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:egregoros, :repo, :query],
      &__MODULE__.handle_repo_query/4,
      parent
    )

    try do
      result = fun.()
      {result, flush_repo_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  def handle_repo_query(_event_name, measurements, metadata, parent)
      when is_pid(parent) and is_map(measurements) and is_map(metadata) do
    send(parent, {:repo_query, measurements, metadata})
  end

  defp flush_repo_queries(acc) do
    receive do
      {:repo_query, measurements, metadata} ->
        flush_repo_queries([{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp pick_query_for_explain(queries) when is_list(queries) do
    queries
    |> Enum.map(&normalize_query/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&explainable_query?/1)
    |> Enum.max_by(& &1.total_time_us, fn -> nil end)
  end

  defp normalize_query({measurements, metadata}) when is_map(measurements) and is_map(metadata) do
    query = Map.get(metadata, :query)
    params = Map.get(metadata, :params, [])
    options = Map.get(metadata, :options)

    total_time_us =
      case Map.get(measurements, :total_time) do
        time when is_integer(time) ->
          System.convert_time_unit(time, :native, :microsecond)

        _ ->
          0
      end

    if is_binary(query) do
      %{query: query, params: params, options: options, total_time_us: total_time_us}
    end
  end

  defp normalize_query(_), do: nil

  defp explainable_query?(%{query: query}) when is_binary(query) do
    query = query |> String.trim_leading() |> String.upcase()

    String.starts_with?(query, ["SELECT", "WITH"])
  end

  defp explainable_query?(_), do: false

  defp run_explain(sql, params, format)
       when is_binary(sql) and is_list(params) and format in [:text, :json] do
    explain_prefix =
      case format do
        :json -> "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "
        :text -> "EXPLAIN (ANALYZE, BUFFERS) "
      end

    result =
      Ecto.Adapters.SQL.query!(
        Egregoros.Repo,
        explain_prefix <> sql,
        params,
        timeout: :infinity
      )

    format_explain_result(result, format)
  end

  defp format_explain_result(%{rows: rows}, :text) when is_list(rows) do
    rows
    |> Enum.map(fn
      [line] -> line
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp format_explain_result(%{rows: rows}, :json) when is_list(rows) do
    payload =
      case rows do
        [[plan]] when is_binary(plan) -> plan
        [[plan]] -> Jason.encode!(plan)
        _ -> Jason.encode!(rows)
      end

    payload <> "\n"
  end

  defp write_output(out_dir, case_name, picked, explain_result, format)
       when is_binary(out_dir) and is_binary(case_name) and is_map(picked) and
              is_binary(explain_result) and
              format in [:text, :json] do
    ext = if format == :json, do: "json", else: "txt"
    file_name = case_name |> sanitize_filename() |> Kernel.<>(".#{ext}")
    file_path = Path.join(out_dir, file_name)

    content = [
      "case: #{case_name}",
      "captured.total_time_us: #{picked.total_time_us}",
      "captured.options: #{inspect(picked.options)}",
      "captured.params: #{inspect(picked.params)}",
      "",
      "captured.sql:",
      picked.query,
      "",
      "explain:",
      explain_result
    ]

    File.write!(file_path, Enum.join(content, "\n"))
    file_path
  end

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_.-]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "bench_explain"
      other -> other
    end
  end

  defp maybe_filter_cases(cases, nil), do: cases

  defp maybe_filter_cases(cases, filter) when is_binary(filter) do
    Enum.filter(cases, fn %{name: name} -> String.contains?(name, filter) end)
  end

  defp maybe_filter_cases(cases, _filter), do: cases

  defp normalize_filter(nil), do: nil

  defp normalize_filter(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_filter(_), do: nil

  defp normalize_out_dir(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "tmp/bench_explain", else: value
  end

  defp normalize_out_dir(_), do: "tmp/bench_explain"

  defp normalize_format(nil), do: :text

  defp normalize_format(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value == "json", do: :json, else: :text
  end

  defp normalize_format(_), do: :text
end
