defmodule PleromaRedux.Objects do
  alias PleromaRedux.Object
  alias PleromaRedux.Repo

  def create_object(attrs) do
    %Object{}
    |> Object.changeset(attrs)
    |> Repo.insert()
  end

  def upsert_object(attrs) do
    case create_object(attrs) do
      {:ok, %Object{} = object} ->
        {:ok, object}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_ap_id_error?(changeset) do
          ap_id = Map.get(attrs, :ap_id) || Map.get(attrs, "ap_id")

          case get_by_ap_id(ap_id) do
            %Object{} = object -> {:ok, object}
            _ -> {:error, changeset}
          end
        else
          {:error, changeset}
        end
    end
  end

  def get_by_ap_id(nil), do: nil
  def get_by_ap_id(ap_id) when is_binary(ap_id), do: Repo.get_by(Object, ap_id: ap_id)

  defp unique_ap_id_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:ap_id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end
end
