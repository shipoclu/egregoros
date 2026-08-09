defmodule Egregoros.OAuth.Scopes do
  @moduledoc false

  def parse(scopes) when is_binary(scopes) do
    scopes
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
  end

  def parse(_), do: []

  def contains_all?(token_scopes, required_scopes)
      when is_binary(token_scopes) and is_list(required_scopes) do
    token_scopes = token_scopes |> parse() |> MapSet.new()
    required_scopes = MapSet.new(required_scopes)
    MapSet.subset?(required_scopes, token_scopes)
  end

  def subset?(requested_scopes, allowed_scopes)
      when is_binary(requested_scopes) and is_binary(allowed_scopes) do
    requested_scopes = requested_scopes |> parse() |> MapSet.new()
    allowed_scopes = MapSet.new(parse(allowed_scopes))

    valid_dependencies?(requested_scopes) and MapSet.subset?(requested_scopes, allowed_scopes)
  end

  defp valid_dependencies?(scopes) do
    not MapSet.member?(scopes, "profile") or MapSet.member?(scopes, "identify")
  end
end
