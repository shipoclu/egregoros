defmodule Egregoros.Activities.Validations do
  @moduledoc false

  import Ecto.Changeset

  def validate_any_presence(changeset, fields) when is_list(fields) do
    present? =
      Enum.any?(fields, fn field ->
        case get_field(changeset, field) do
          nil -> false
          [] -> false
          "" -> false
          _ -> true
        end
      end)

    if present? do
      changeset
    else
      Enum.reduce(fields, changeset, fn field, acc ->
        add_error(acc, field, "none of #{inspect(fields)} present")
      end)
    end
  end

  def validate_fields_match(changeset, fields) when is_list(fields) do
    values = Enum.map(fields, &get_field(changeset, &1))
    unique = Enum.uniq(values)

    if length(unique) == 1 and hd(unique) != nil do
      changeset
    else
      Enum.reduce(fields, changeset, fn field, acc ->
        add_error(acc, field, "Fields #{inspect(fields)} aren't matching")
      end)
    end
  end

  def validate_host_match(changeset, fields) when is_list(fields) do
    hosts =
      Enum.map(fields, fn field ->
        case get_field(changeset, field) do
          value when is_binary(value) -> URI.parse(value).host
          _ -> nil
        end
      end)

    if hosts != [] and Enum.all?(hosts, &is_binary/1) and length(Enum.uniq(hosts)) == 1 do
      changeset
    else
      Enum.reduce(fields, changeset, fn field, acc ->
        add_error(acc, field, "hosts of #{inspect(fields)} aren't matching")
      end)
    end
  end
end
