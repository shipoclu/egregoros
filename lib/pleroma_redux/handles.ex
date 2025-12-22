defmodule PleromaRedux.Handles do
  @moduledoc false

  @type parsed_acct :: %{nickname: String.t(), domain: String.t() | nil}

  @spec parse_acct(term()) :: {:ok, parsed_acct()} | :error
  def parse_acct(acct) when is_binary(acct) do
    acct =
      acct
      |> String.trim()
      |> String.trim_leading("@")

    parts = String.split(acct, "@", trim: true)

    case parts do
      [nickname] when nickname != "" ->
        {:ok, %{nickname: nickname, domain: nil}}

      [nickname, domain | _rest] when nickname != "" and domain != "" ->
        {:ok, %{nickname: nickname, domain: domain}}

      _ ->
        :error
    end
  end

  def parse_acct(_), do: :error
end
