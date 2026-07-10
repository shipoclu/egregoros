defmodule Egregoros.Activities.FollowResponseAuthorization do
  @moduledoc false

  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Relationship
  alias Egregoros.Relationships

  def authorize(activity, opts) when is_list(opts) do
    if Keyword.get(opts, :local, true), do: :ok, else: authorize_remote(activity)
  end

  defp authorize_remote(%{"id" => response_id} = activity) when is_binary(response_id) do
    if duplicate_response?(activity) do
      :ok
    else
      authorize_new_response(activity)
    end
  end

  defp authorize_remote(_activity), do: {:error, :uncorrelated_follow_response}

  defp authorize_new_response(%{"actor" => response_actor, "object" => object})
       when is_binary(response_actor) do
    with {:ok, follow_id, embedded_follow} <- follow_reference(object),
         %Object{type: "Follow"} = stored_follow <- Objects.get_by_ap_id(follow_id),
         :ok <- validate_embedded_follow(embedded_follow, stored_follow),
         true <- response_actor == stored_follow.object,
         %Relationship{activity_ap_id: ^follow_id} <-
           Relationships.get_by_type_actor_object(
             "FollowRequest",
             stored_follow.actor,
             stored_follow.object
           ) do
      :ok
    else
      :not_follow -> :ok
      _ -> {:error, :uncorrelated_follow_response}
    end
  end

  defp authorize_new_response(_activity), do: {:error, :uncorrelated_follow_response}

  defp follow_reference(%{"type" => "Follow", "id" => id} = follow) when is_binary(id),
    do: {:ok, id, follow}

  defp follow_reference(%{"type" => type}) when is_binary(type), do: :not_follow

  defp follow_reference(id) when is_binary(id) do
    case Objects.get_by_ap_id(id) do
      %Object{type: "Follow"} -> {:ok, id, nil}
      _ -> :not_follow
    end
  end

  defp follow_reference(_object), do: :not_follow

  defp validate_embedded_follow(nil, %Object{}), do: :ok

  defp validate_embedded_follow(%{} = embedded, %Object{} = stored) do
    actor = extract_id(Map.get(embedded, "actor"))
    target = extract_id(Map.get(embedded, "object"))

    if embedded["id"] == stored.ap_id and actor == stored.actor and target == stored.object,
      do: :ok,
      else: {:error, :uncorrelated_follow_response}
  end

  defp duplicate_response?(%{"id" => response_id} = activity) do
    case Objects.get_by_ap_id(response_id) do
      %Object{type: type, data: data} when type in ["Accept", "Reject"] -> data == activity
      _ -> false
    end
  end

  defp extract_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_id(id) when is_binary(id), do: id
  defp extract_id(_value), do: nil
end
