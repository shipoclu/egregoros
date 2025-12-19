defmodule PleromaRedux.ActivityRegistry do
  alias PleromaRedux.Activities.Note

  @registry %{
    "Note" => Note
  }

  def fetch(%{"type" => type}), do: fetch(type)

  def fetch(type) when is_binary(type) do
    case Map.fetch(@registry, type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_type}
    end
  end
end
