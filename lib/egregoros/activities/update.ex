defmodule Egregoros.Activities.Update do
  use Ecto.Schema

  import Ecto.Changeset

  alias Egregoros.Activities.Helpers
  alias Egregoros.ActivityPub.ObjectValidators.Types.DateTime, as: APDateTime
  alias Egregoros.ActivityPub.ObjectValidators.Types.ObjectID
  alias Egregoros.ActivityPub.ObjectValidators.Types.Recipients
  alias Egregoros.Federation.Actor
  alias Egregoros.InboxTargeting
  alias Egregoros.Object
  alias Egregoros.Objects

  @actor_types ~w(Person Service Organization Group Application)

  def type, do: "Update"

  @primary_key false
  embedded_schema do
    field :id, ObjectID
    field :type, :string
    field :actor, ObjectID
    field :object, :map
    field :to, Recipients
    field :cc, Recipients
    field :published, APDateTime
  end

  def cast_and_validate(activity) when is_map(activity) do
    activity = normalize_actor(activity)

    changeset =
      %__MODULE__{}
      |> cast(activity, __schema__(:fields))
      |> validate_required([:id, :type, :actor, :object])
      |> validate_inclusion(:type, [type()])
      |> validate_object()

    case apply_action(changeset, :insert) do
      {:ok, %__MODULE__{} = update} -> {:ok, apply_update(activity, update)}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  def ingest(activity, opts) do
    with :ok <- validate_inbox_target(activity, opts) do
      activity
      |> to_object_attrs(opts)
      |> Objects.upsert_object()
    end
  end

  def side_effects(%Object{data: %{"object" => %{} = object}, actor: actor_ap_id}, _opts)
      when is_binary(actor_ap_id) do
    maybe_apply_actor_update(actor_ap_id, object)
    :ok
  end

  def side_effects(_object, _opts), do: :ok

  defp maybe_apply_actor_update(actor_ap_id, %{"type" => type} = object)
       when is_binary(type) and type in @actor_types do
    object_id = Map.get(object, "id")

    if is_binary(object_id) and object_id == actor_ap_id do
      _ = Actor.upsert_from_map(object)
    end

    :ok
  end

  defp maybe_apply_actor_update(_actor_ap_id, _object), do: :ok

  defp validate_inbox_target(%{} = activity, opts) when is_list(opts) do
    InboxTargeting.validate(opts, fn inbox_user_ap_id ->
      actor_ap_id = Map.get(activity, "actor")

      cond do
        InboxTargeting.addressed_to?(activity, inbox_user_ap_id) ->
          :ok

        InboxTargeting.follows?(inbox_user_ap_id, actor_ap_id) ->
          :ok

        true ->
          {:error, :not_targeted}
      end
    end)
  end

  defp validate_inbox_target(_activity, _opts), do: :ok

  defp to_object_attrs(activity, opts) do
    %{
      ap_id: activity["id"],
      type: activity["type"],
      actor: activity["actor"],
      object: object_id(activity),
      data: activity,
      published: Helpers.parse_datetime(activity["published"]),
      local: Keyword.get(opts, :local, true)
    }
  end

  defp object_id(%{"object" => %{"id" => id}}) when is_binary(id), do: id
  defp object_id(_activity), do: nil

  defp apply_update(activity, %__MODULE__{} = update) do
    activity
    |> Map.put("id", update.id)
    |> Map.put("type", update.type)
    |> Map.put("actor", update.actor)
    |> Map.put("object", update.object)
    |> Helpers.maybe_put("to", update.to)
    |> Helpers.maybe_put("cc", update.cc)
    |> Helpers.maybe_put("published", update.published)
  end

  defp normalize_actor(%{"actor" => %{"id" => id}} = activity) when is_binary(id) do
    Map.put(activity, "actor", id)
  end

  defp normalize_actor(activity), do: activity

  defp validate_object(changeset) do
    update_actor = get_field(changeset, :actor)

    validate_change(changeset, :object, fn :object, object_value ->
      object_id = get_in(object_value, ["id"]) || get_in(object_value, [:id])
      object_type = get_in(object_value, ["type"]) || get_in(object_value, [:type])

      errors =
        if is_binary(object_id) and String.trim(object_id) != "" and is_binary(object_type) and
             String.trim(object_type) != "" do
          []
        else
          [object: "must be an object with id and type"]
        end

      if is_binary(update_actor) and update_actor != "" and object_type in @actor_types and
           object_id != update_actor do
        errors ++ [object: "actor does not match Update actor"]
      else
        errors
      end
    end)
  end
end

