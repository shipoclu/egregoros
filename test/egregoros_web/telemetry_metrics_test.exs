defmodule EgregorosWeb.TelemetryMetricsTest do
  use ExUnit.Case, async: true

  test "includes a metric for timeline read spans" do
    metrics = EgregorosWeb.Telemetry.metrics()

    assert Enum.any?(metrics, fn
             %Telemetry.Metrics.Summary{name: [:egregoros, :timeline, :read, :stop, :duration]} ->
               true

             _ ->
               false
           end)
  end
end
