defmodule EgregorosWeb.ParamTest do
  use ExUnit.Case, async: true

  alias EgregorosWeb.Param

  test "truthy?/1 matches common boolean-ish values" do
    assert Param.truthy?(true)
    assert Param.truthy?(1)
    assert Param.truthy?("1")
    assert Param.truthy?("true")

    refute Param.truthy?(false)
    refute Param.truthy?(0)
    refute Param.truthy?("0")
    refute Param.truthy?("TRUE")
    refute Param.truthy?(nil)
  end
end
