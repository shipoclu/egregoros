defmodule Egregoros.Bench.SuiteTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Bench.Suite
  alias Egregoros.Users

  test "default_cases returns a list of named benchmark cases" do
    {:ok, _user} = Users.create_local_user("bench-user")

    cases = Suite.default_cases()

    assert is_list(cases)
    assert length(cases) == 7

    Enum.each(cases, fn %{name: name, fun: fun} ->
      assert is_binary(name)
      assert is_function(fun, 0)
      assert is_list(fun.())
    end)
  end
end
