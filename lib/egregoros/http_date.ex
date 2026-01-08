defmodule Egregoros.HTTPDate do
  @moduledoc false

  @month_abbr_to_int %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  def format_rfc1123(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  def parse_rfc1123(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_rfc1123_trimmed()
  end

  def parse_rfc1123(_value), do: {:error, :invalid_date}

  defp parse_rfc1123_trimmed(value) when is_binary(value) do
    with [_weekday, rest] <- String.split(value, ",", parts: 2),
         {:ok, dt} <- parse_date_time(String.trim(rest)) do
      {:ok, dt}
    else
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date_time(value) when is_binary(value) do
    case String.split(value, " ", trim: true) do
      [day_str, month_str, year_str, time_str, zone] ->
        with {:ok, day} <- parse_int(day_str),
             {:ok, month} <- parse_month(month_str),
             {:ok, year} <- parse_int(year_str),
             {:ok, {hour, minute, second}} <- parse_time(time_str),
             true <- String.upcase(zone) in ["GMT", "UTC"],
             {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second),
             {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, dt}
        else
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_date}
    end
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_int(_value), do: {:error, :invalid_date}

  defp parse_month(value) when is_binary(value) do
    case @month_abbr_to_int[String.downcase(value)] do
      month when is_integer(month) -> {:ok, month}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_month(_value), do: {:error, :invalid_date}

  defp parse_time(value) when is_binary(value) do
    case String.split(value, ":", parts: 3) do
      [hour_str, min_str, sec_str] ->
        with {:ok, hour} <- parse_int(hour_str),
             {:ok, minute} <- parse_int(min_str),
             {:ok, second} <- parse_int(sec_str) do
          {:ok, {hour, minute, second}}
        else
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_date}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_date}
end

