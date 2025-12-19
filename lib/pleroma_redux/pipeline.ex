defmodule PleromaRedux.Pipeline do
  alias PleromaRedux.ActivityRegistry

  def ingest(activity, opts \\ []) when is_map(activity) do
    with {:ok, module} <- ActivityRegistry.fetch(activity),
         normalized when is_map(normalized) <- module.normalize(activity),
         {:ok, validated} <- module.validate(normalized),
         {:ok, object} <- module.ingest(validated, opts),
         :ok <- module.side_effects(object, opts) do
      {:ok, object}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end
end
