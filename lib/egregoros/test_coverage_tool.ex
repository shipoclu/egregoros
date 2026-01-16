defmodule Egregoros.TestCoverageTool do
  @moduledoc false
  @compile {:no_warn_undefined, :cover}

  @default_threshold 90

  @doc false
  def start(compile_path, opts) do
    Mix.shell().info("Cover compiling modules ...")
    Mix.ensure_application!(:tools)

    if Keyword.get(opts, :local_only, true) do
      :cover.local_only()
    end

    cover_compile([compile_path])

    if name = opts[:export] do
      fn ->
        Mix.shell().info("\nExporting cover results ...\n")
        export_cover_results(name, opts)
      end
    else
      fn ->
        Mix.shell().info("\nGenerating cover results ...\n")
        generate_cover_results(opts)
      end
    end
  end

  @doc false
  def coverage_summary(results, keep) do
    keep_set = MapSet.new(keep)
    table = :ets.new(__MODULE__, [:set, :private])

    try do
      for {{module, line}, cov} <- results, module in keep_set, line != 0 do
        case cov do
          {1, 0} -> :ets.insert(table, {{module, line}, true})
          {0, 1} -> :ets.insert_new(table, {{module, line}, false})
          _ -> :ok
        end
      end

      module_results = for module <- keep, do: {read_cover_results(table, module), module}
      {module_results, read_cover_results(table, :_)}
    after
      :ets.delete(table)
    end
  end

  @doc false
  def normalize_analyse_to_file_result(result)

  def normalize_analyse_to_file_result(:ok), do: :ok
  def normalize_analyse_to_file_result({:ok, _path}), do: :ok
  def normalize_analyse_to_file_result({:error, _reason} = error), do: error
  def normalize_analyse_to_file_result(other), do: {:error, other}

  defp cover_compile(compile_paths) do
    _ = :cover.stop()
    {:ok, pid} = :cover.start()

    for compile_path <- compile_paths do
      case :cover.compile_beam(beams(compile_path)) do
        results when is_list(results) ->
          :ok

        {:error, reason} ->
          Mix.raise(
            "Failed to cover compile directory #{inspect(Path.relative_to_cwd(compile_path))} " <>
              "with reason: #{inspect(reason)}"
          )
      end
    end

    pid
  end

  defp beams(dir) do
    consolidation_dir = Mix.Project.consolidation_path()

    consolidated =
      case File.ls(consolidation_dir) do
        {:ok, files} -> files
        _ -> []
      end

    for file <- File.ls!(dir), Path.extname(file) == ".beam" do
      with true <- file in consolidated,
           [_ | _] = path <- :code.which(file |> Path.rootname() |> String.to_atom()) do
        path
      else
        _ -> String.to_charlist(Path.join(dir, file))
      end
    end
  end

  defp export_cover_results(name, opts) do
    output = Keyword.get(opts, :output, "cover")
    File.mkdir_p!(output)

    case :cover.export(~c"#{output}/#{name}.coverdata") do
      :ok ->
        Mix.shell().info("Run \"mix test.coverage\" once all exports complete")

      {:error, reason} ->
        Mix.shell().error("Export failed with reason: #{inspect(reason)}")
    end
  end

  defp generate_cover_results(opts) do
    {:result, results, _fail} = :cover.analyse(:coverage, :line)
    ignore = opts[:ignore_modules] || []
    modules = Enum.reject(:cover.modules(), &ignored?(&1, ignore))

    if summary_opts = Keyword.get(opts, :summary, true) do
      summary(results, modules, summary_opts)
    end

    html(modules, opts)
  end

  defp ignored?(mod, ignores) do
    Enum.any?(ignores, &ignored_any?(mod, &1))
  end

  defp ignored_any?(mod, %Regex{} = re), do: Regex.match?(re, inspect(mod))
  defp ignored_any?(mod, other), do: mod == other

  defp html(modules, opts) do
    output = Keyword.get(opts, :output, "cover")
    File.mkdir_p!(output)

    Enum.each(modules, fn mod ->
      path = String.to_charlist(Path.join(output, "#{mod}.html"))

      case normalize_analyse_to_file_result(:cover.analyse_to_file(mod, path, [:html])) do
        :ok ->
          :ok

        {:error, reason} ->
          Mix.shell().error("Cover export failed for #{inspect(mod)}: #{inspect(reason)}")
      end
    end)

    Mix.shell().info("Generated HTML coverage results in #{inspect(output)} directory")
  end

  defp summary(results, keep, summary_opts) do
    {module_results, totals} = coverage_summary(results, keep)
    module_results = Enum.sort(module_results, :desc)
    print_summary(module_results, totals, summary_opts)

    if totals < get_threshold(summary_opts) do
      print_failed_threshold(totals, get_threshold(summary_opts))
      System.at_exit(fn _ -> exit({:shutdown, 3}) end)
    end

    :ok
  end

  defp print_summary(results, totals, true), do: print_summary(results, totals, [])

  defp print_summary(results, totals, opts) when is_list(opts) do
    threshold = get_threshold(opts)

    results =
      results |> Enum.sort() |> Enum.map(fn {coverage, module} -> {coverage, inspect(module)} end)

    name_max_length = results |> Enum.map(&String.length(elem(&1, 1))) |> Enum.max() |> max(10)
    name_separator = String.duplicate("-", name_max_length)

    Mix.shell().info("| Percentage | #{String.pad_trailing("Module", name_max_length)} |")
    Mix.shell().info("|------------|-#{name_separator}-|")
    Enum.each(results, &display(&1, threshold, name_max_length))
    Mix.shell().info("|------------|-#{name_separator}-|")
    display({totals, "Total"}, threshold, name_max_length)
    Mix.shell().info("")
  end

  defp print_failed_threshold(totals, threshold) do
    Mix.shell().info("Coverage test failed, threshold not met:\n")
    Mix.shell().info("    Coverage:  #{format_number(totals, 6)}%")
    Mix.shell().info("    Threshold: #{format_number(threshold, 6)}%")
    Mix.shell().info("")
  end

  defp display({percentage, name}, threshold, pad_length) do
    Mix.shell().info([
      "| ",
      color(percentage, threshold),
      format_number(percentage, 9),
      "%",
      :reset,
      " | ",
      String.pad_trailing(name, pad_length),
      " |"
    ])
  end

  defp color(percentage, true), do: color(percentage, @default_threshold)
  defp color(_, false), do: ""
  defp color(percentage, threshold) when percentage >= threshold, do: :green
  defp color(_, _), do: :red

  defp format_number(number, length) when is_integer(number),
    do: format_number(number / 1, length)

  defp format_number(number, length), do: :io_lib.format("~#{length}.2f", [number])

  defp get_threshold(true), do: @default_threshold
  defp get_threshold(opts), do: Keyword.get(opts, :threshold, @default_threshold)

  defp read_cover_results(table, module) do
    covered = :ets.select_count(table, [{{{module, :_}, true}, [], [true]}])
    not_covered = :ets.select_count(table, [{{{module, :_}, false}, [], [true]}])
    percentage(covered, not_covered)
  end

  defp percentage(0, 0), do: 100.0
  defp percentage(covered, not_covered), do: covered / (covered + not_covered) * 100
end
