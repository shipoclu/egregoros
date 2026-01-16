defmodule Egregoros.TestCoverageToolTest do
  use ExUnit.Case, async: true

  describe "coverage_summary/2" do
    defmodule Foo do
    end

    defmodule Bar do
    end

    test "counts each executable line once and ignores line 0" do
      results = [
        {{Foo, 1}, {1, 0}},
        {{Foo, 2}, {0, 1}},
        {{Foo, 2}, {1, 0}},
        {{Foo, 0}, {0, 1}},
        {{Bar, 1}, {0, 1}},
        {{Bar, 1}, {0, 1}},
        {{Bar, 2}, {0, 1}}
      ]

      {module_results, total} = Egregoros.TestCoverageTool.coverage_summary(results, [Foo, Bar])

      assert Enum.member?(module_results, {100.0, Foo})
      assert Enum.member?(module_results, {0.0, Bar})
      assert_in_delta total, 50.0, 0.0001
    end

    test "treats 0/0 as 100%" do
      {module_results, total} = Egregoros.TestCoverageTool.coverage_summary([], [Foo])

      assert module_results == [{100.0, Foo}]
      assert total == 100.0
    end
  end

  describe "normalize_analyse_to_file_result/1" do
    test "treats {:ok, _} as success" do
      assert :ok ==
               Egregoros.TestCoverageTool.normalize_analyse_to_file_result(
                 {:ok, ~c"cover/Elixir.Egregoros.SomeModule.html"}
               )
    end

    test "passes through :ok" do
      assert :ok == Egregoros.TestCoverageTool.normalize_analyse_to_file_result(:ok)
    end

    test "passes through {:error, reason}" do
      assert {:error, :nope} ==
               Egregoros.TestCoverageTool.normalize_analyse_to_file_result({:error, :nope})
    end
  end

  test "does not use concurrent HTML generation" do
    source = File.read!("lib/egregoros/test_coverage_tool.ex")
    refute source =~ "async_analyse_to_file"
    assert source =~ "analyse_to_file"
  end
end
