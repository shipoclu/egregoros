defmodule PleromaRedux.Pipeline do
  alias PleromaRedux.ActivityRegistry

  def ingest(activity, opts \\ []) when is_map(activity) do
    with {:ok, module} <- ActivityRegistry.fetch(activity) do
      ingest_with(module, activity, opts)
    end
  end

  @doc false
  def ingest_with(module, activity, opts \\ [])
      when is_atom(module) and is_map(activity) and is_list(opts) do
    with {:ok, validated} <- cast_and_validate(module, activity),
         {:ok, object} <- module.ingest(validated, opts),
         :ok <- module.side_effects(object, opts) do
      {:ok, object}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end

  defp cast_and_validate(module, activity) do
    if function_exported?(module, :cast_and_validate, 1) do
      case module.cast_and_validate(activity) do
        {:ok, validated} when is_map(validated) -> {:ok, validated}
        {:error, %Ecto.Changeset{}} -> {:error, :invalid}
        {:error, _} = error -> error
        _ -> {:error, :invalid}
      end
    else
      {:error, :invalid}
    end
  end
end
