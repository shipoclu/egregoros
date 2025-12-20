defmodule PleromaReduxWeb.Time do
  @moduledoc false

  @minute 60
  @hour 60 * @minute
  @day 24 * @hour
  @week 7 * @day
  @year 365 * @day

  def to_datetime(%DateTime{} = dt), do: dt

  def to_datetime(%NaiveDateTime{} = dt) do
    DateTime.from_naive!(dt, "Etc/UTC")
  end

  def to_datetime(_), do: nil

  def iso8601(value) do
    case to_datetime(value) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  def relative(value, now \\ DateTime.utc_now())

  def relative(value, %DateTime{} = now) do
    case to_datetime(value) do
      %DateTime{} = dt ->
        seconds =
          now
          |> DateTime.diff(dt, :second)
          |> max(0)

        cond do
          seconds < 10 -> "now"
          seconds < @minute -> "#{seconds}s"
          seconds < @hour -> "#{div(seconds, @minute)}m"
          seconds < @day -> "#{div(seconds, @hour)}h"
          seconds < @week -> "#{div(seconds, @day)}d"
          seconds < @year -> "#{div(seconds, @week)}w"
          true -> "#{div(seconds, @year)}y"
        end

      _ ->
        ""
    end
  end
end
