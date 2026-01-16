defmodule Egregoros.TestSupport.PipelineCastAndValidateProbeTest do
  use ExUnit.Case, async: true

  alias Egregoros.TestSupport.PipelineCastAndValidateProbe, as: Probe

  test "cast_and_validate/1 marks the activity as validated" do
    assert {:ok, %{"validated?" => true}} = Probe.cast_and_validate(%{"type" => "Create"})
  end

  test "normalize/1 and validate/1 raise when cast_and_validate/1 is available" do
    assert_raise RuntimeError, ~r/must not be called/, fn -> Probe.normalize(%{}) end
    assert_raise RuntimeError, ~r/must not be called/, fn -> Probe.validate(%{}) end
  end

  test "ingest/2 and side_effects/2 are no-ops" do
    assert {:ok, %{"type" => "Create"}} = Probe.ingest(%{"type" => "Create"}, [])
    assert :ok = Probe.side_effects(%{}, [])
  end

  test "type/0 returns the probe type name" do
    assert Probe.type() == "PipelineCastAndValidateProbe"
  end
end
