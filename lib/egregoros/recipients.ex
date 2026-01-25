defmodule Egregoros.Recipients do
  @moduledoc false

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @default_fields ~w(to cc bto bcc audience)

  @field_atoms %{
    "to" => :to,
    "cc" => :cc,
    "bto" => :bto,
    "bcc" => :bcc,
    "audience" => :audience
  }

  def recipient_actor_ids(data, opts \\ [])

  def recipient_actor_ids(%Egregoros.Object{data: %{} = data}, opts) when is_list(opts) do
    recipient_actor_ids(data, opts)
  end

  def recipient_actor_ids(%{} = data, opts) when is_list(opts) do
    fields = Keyword.get(opts, :fields, @default_fields)
    as_public = Keyword.get(opts, :as_public, @as_public)
    reject_public? = Keyword.get(opts, :reject_public, true)
    reject_followers? = Keyword.get(opts, :reject_followers, true)

    fields
    |> Enum.flat_map(fn field ->
      data
      |> get_field(field)
      |> List.wrap()
      |> Enum.map(&extract_recipient_id/1)
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn recipient_id ->
      recipient_id == "" or
        (reject_public? and recipient_id == as_public) or
        (reject_followers? and String.ends_with?(recipient_id, "/followers"))
    end)
    |> Enum.uniq()
  end

  def recipient_actor_ids(_data, _opts), do: []

  defp get_field(%{} = data, field) when is_binary(field) do
    case Map.get(@field_atoms, field) do
      atom when is_atom(atom) -> Map.get(data, field) || Map.get(data, atom)
      _ -> Map.get(data, field)
    end
  end

  defp get_field(%{} = data, field) when is_atom(field) do
    Map.get(data, field) || Map.get(data, Atom.to_string(field))
  end

  defp get_field(_data, _field), do: nil

  defp extract_recipient_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_recipient_id(%{id: id}) when is_binary(id), do: id
  defp extract_recipient_id(id) when is_binary(id), do: id
  defp extract_recipient_id(_recipient), do: nil
end
