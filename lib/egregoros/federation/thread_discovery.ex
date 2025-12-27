defmodule Egregoros.Federation.ThreadDiscovery do
  @moduledoc false

  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Workers.FetchThreadAncestors

  @default_max_depth 20

  def enqueue(object, opts \\ [])

  def enqueue(%Object{type: "Note", ap_id: ap_id, data: %{} = data} = object, opts)
      when is_list(opts) do
    parent_ap_id =
      data
      |> Map.get("inReplyTo")
      |> in_reply_to_ap_id()

    if should_enqueue?(object, parent_ap_id) do
      args = %{"start_ap_id" => ap_id, "max_depth" => @default_max_depth}
      _ = Oban.insert(FetchThreadAncestors.new(args))
      :ok
    else
      :ok
    end
  end

  def enqueue(_object, _opts), do: :ok

  defp should_enqueue?(_object, parent_ap_id) when not is_binary(parent_ap_id), do: false

  defp should_enqueue?(_object, parent_ap_id) do
    parent_ap_id = String.trim(parent_ap_id)

    cond do
      parent_ap_id == "" -> false
      not String.starts_with?(parent_ap_id, ["http://", "https://"]) -> false
      Objects.get_by_ap_id(parent_ap_id) != nil -> false
      true -> true
    end
  end

  defp in_reply_to_ap_id(value) when is_binary(value), do: value
  defp in_reply_to_ap_id(%{"id" => id}) when is_binary(id), do: id
  defp in_reply_to_ap_id(_), do: nil
end
