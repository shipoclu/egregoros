defmodule EgregorosWeb.ReplyPrefill do
  @moduledoc false

  alias Egregoros.Mentions
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.User
  alias EgregorosWeb.ViewModels.Actor, as: ActorVM

  def reply_content(in_reply_to_ap_id, actor_handle, current_user) do
    in_reply_to_ap_id =
      in_reply_to_ap_id
      |> to_string()
      |> String.trim()

    actor_handle =
      actor_handle
      |> to_string()
      |> String.trim()

    current_user_handle =
      case current_user do
        %User{ap_id: ap_id} when is_binary(ap_id) -> ActorVM.handle(current_user, ap_id)
        _ -> nil
      end

    handles =
      [actor_handle | mention_handles(in_reply_to_ap_id)]
      |> Enum.filter(&valid_handle?/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == current_user_handle))
      |> Enum.uniq()

    if handles == [] do
      ""
    else
      Enum.join(handles, " ") <> " "
    end
  end

  defp mention_handles(in_reply_to_ap_id) when is_binary(in_reply_to_ap_id) do
    in_reply_to_ap_id = String.trim(in_reply_to_ap_id)

    if in_reply_to_ap_id == "" do
      []
    else
      case Objects.get_by_ap_id(in_reply_to_ap_id) do
        %Object{data: %{} = data} ->
          data
          |> Map.get("tag", [])
          |> List.wrap()
          |> Enum.flat_map(&mention_handle_from_tag/1)

        _ ->
          []
      end
    end
  end

  defp mention_handles(_in_reply_to_ap_id), do: []

  defp mention_handle_from_tag(%{"type" => "Mention"} = tag) do
    tag
    |> mention_handle_from_tag_name()
    |> Kernel.++(mention_handle_from_tag_href(tag))
  end

  defp mention_handle_from_tag(%{type: "Mention"} = tag) do
    tag
    |> mention_handle_from_tag_name()
    |> Kernel.++(mention_handle_from_tag_href(tag))
  end

  defp mention_handle_from_tag(_tag), do: []

  defp mention_handle_from_tag_name(%{} = tag) do
    name = Map.get(tag, "name") || Map.get(tag, :name)

    if valid_handle?(name) do
      [String.trim(name)]
    else
      []
    end
  end

  defp mention_handle_from_tag_href(%{} = tag) do
    href = Map.get(tag, "href") || Map.get(tag, :href) || Map.get(tag, "id") || Map.get(tag, :id)

    if is_binary(href) and String.trim(href) != "" do
      handle =
        href
        |> String.trim()
        |> ActorVM.card()
        |> Map.get(:handle)

      if valid_handle?(handle) do
        [String.trim(handle)]
      else
        []
      end
    else
      []
    end
  end

  defp valid_handle?(handle) when is_binary(handle) do
    handle = String.trim(handle)

    if handle == "" do
      false
    else
      match?({:ok, _, _}, Mentions.parse(handle))
    end
  end

  defp valid_handle?(_handle), do: false
end
