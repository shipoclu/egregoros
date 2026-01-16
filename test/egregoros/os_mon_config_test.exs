defmodule Egregoros.OsMonConfigTest do
  use ExUnit.Case, async: true

  test "os_mon supervisors are disabled in tests" do
    assert Application.get_env(:os_mon, :start_cpu_sup) == false
    assert Application.get_env(:os_mon, :start_memsup) == false
    assert Application.get_env(:os_mon, :start_disksup) == false
  end
end
