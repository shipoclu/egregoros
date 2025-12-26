defmodule Egregoros.PipelineCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Pipeline
  alias Egregoros.TestSupport.PipelineCastAndValidateProbe

  test "ingest_with/3 uses cast_and_validate/1 when available" do
    activity = %{"type" => PipelineCastAndValidateProbe.type(), "id" => "x"}

    assert {:ok, %{"validated?" => true}} =
             Pipeline.ingest_with(PipelineCastAndValidateProbe, activity, [])
  end
end
