defmodule Egregoros.Bench.SuiteTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Bench.Suite
  alias Egregoros.Users

  test "default_cases returns a list of named benchmark cases" do
    {:ok, _user} = Users.create_local_user("bench-user")

    cases = Suite.default_cases()

    assert is_list(cases)
    assert length(cases) >= 7

    case_names = Enum.map(cases, &Map.get(&1, :name))
    assert MapSet.size(MapSet.new(case_names)) == length(cases)

    for expected <- [
          "timeline.public.list_notes(limit=20)",
          "timeline.home.list_home_notes(limit=20)",
          "render.status_vm.decorate_many(20)",
          "notifications.list_for_user(limit=20)"
        ] do
      assert expected in case_names
    end

    Enum.each(cases, fn %{name: name, fun: fun} ->
      assert is_binary(name)
      assert is_function(fun, 0)
      assert is_list(fun.())
    end)
  end
end
