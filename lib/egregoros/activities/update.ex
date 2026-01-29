defmodule Egregoros.Activities.Update do
  use Ecto.Schema

  import Ecto.Changeset

  alias Egregoros.Activities.Helpers
  alias Egregoros.Activities.Note
  alias Egregoros.ActivityPub.ObjectValidators.Types.DateTime, as: APDateTime
  alias Egregoros.ActivityPub.ObjectValidators.Types.ObjectID
  alias Egregoros.ActivityPub.ObjectValidators.Types.Recipients
  alias Egregoros.ActivityPub.TypeNormalizer
  alias Egregoros.Domain
  alias Egregoros.Federation.Delivery
  alias Egregoros.Federation.Actor
  alias Egregoros.InboxTargeting
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Relationships
  alias Egregoros.Timeline
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  @actor_types ~w(Person Service Organization Group Application)
  @as_public "https://www.w3.org/ns/activitystreams#Public"

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

  def build(%User{ap_id: actor}, object) when is_map(object) do
    build(actor, object)
  end

  def build(actor, object) when is_binary(actor) and is_map(object) do
    to = object |> Map.get("to", []) |> List.wrap()
    cc = object |> Map.get("cc", []) |> List.wrap()

    %{
      "id" => Endpoint.url() <> "/activities/update/" <> Ecto.UUID.generate(),
      "type" => type(),
      "actor" => actor,
      "object" => object,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> maybe_put_recipients("to", to)
    |> maybe_put_recipients("cc", cc)
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
    with :ok <- validate_inbox_target(activity, opts),
         :ok <- validate_object_namespace(activity, opts),
         :ok <- validate_credential_update(activity) do
      activity
      |> to_object_attrs(opts)
      |> Objects.upsert_object()
    end
  end

  def side_effects(
        %Object{data: %{"object" => %{} = embedded_object}, actor: actor_ap_id} = update_object,
        opts
      )
      when is_binary(actor_ap_id) do
    maybe_apply_actor_update(actor_ap_id, embedded_object)
    maybe_apply_note_update(actor_ap_id, embedded_object, opts)
    maybe_apply_credential_update(actor_ap_id, embedded_object, opts)

    if Keyword.get(opts, :local, true) do
      deliver_update(update_object, opts)
    end

    :ok
  end

  def side_effects(_object, _opts), do: :ok

  defp maybe_apply_actor_update(actor_ap_id, %{} = object) when is_binary(actor_ap_id) do
    case TypeNormalizer.primary_type(object) do
      type when is_binary(type) and type in @actor_types ->
        object_id = Map.get(object, "id")

        if is_binary(object_id) and object_id == actor_ap_id do
          _ = Actor.upsert_from_map(object)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_apply_actor_update(_actor_ap_id, _object), do: :ok

  defp maybe_apply_note_update(actor_ap_id, %{} = object, opts)
       when is_binary(actor_ap_id) and is_list(opts) do
    note_id = Map.get(object, "id")

    with note_id when is_binary(note_id) and note_id != "" <- note_id,
         # Normalize multi-type objects so Note validation still works, while keeping
         # metadata around to restore the canonical type array on persistence.
         {:ok, normalized_object, type_metadata} <- TypeNormalizer.normalize_incoming(object),
         existing_note <- Objects.get_by_ap_id(note_id),
         {:ok, validated_note} <- Note.cast_and_validate(normalized_object),
         note_actor when is_binary(note_actor) <- Map.get(validated_note, "actor"),
         true <- note_actor == actor_ap_id do
      note_opts = TypeNormalizer.put_type_metadata(opts, type_metadata)
      note_attrs = Note.to_object_attrs(validated_note, note_opts)

      note_attrs =
        if existing_note do
          merged_data = Map.merge(existing_note.data || %{}, Map.get(note_attrs, :data, %{}))

          note_attrs
          |> Map.put(:data, merged_data)
          |> Map.put(:published, Map.get(note_attrs, :published) || existing_note.published)
          |> Map.put(:local, existing_note.local)
        else
          note_attrs
        end

      case Objects.upsert_object(note_attrs, conflict: :replace) do
        {:ok, %Object{} = note_object} ->
          if existing_note do
            Timeline.broadcast_post_updated(note_object)
          else
            Timeline.broadcast_post(note_object)
          end

          :ok

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp maybe_apply_note_update(_actor_ap_id, _object, _opts), do: :ok

  defp maybe_apply_credential_update(actor_ap_id, %{} = object, opts)
       when is_binary(actor_ap_id) and is_list(opts) do
    credential_id = Map.get(object, "id") || Map.get(object, :id)
    issuer_id = credential_issuer_id(object)

    with "VerifiableCredential" <- TypeNormalizer.primary_type(object),
         credential_id when is_binary(credential_id) <- credential_id,
         %Object{} = existing <- Objects.get_by_ap_id(credential_id),
         issuer_id when is_binary(issuer_id) <- issuer_id,
         true <- issuer_id == actor_ap_id,
         {:ok, updated_to, _added_public?} <- public_update_allowed?(existing.data, object) do
      updated_data = Map.put(existing.data, "to", updated_to)

      attrs = %{
        ap_id: existing.ap_id,
        type: existing.type,
        actor: existing.actor,
        object: existing.object,
        data: updated_data,
        published: existing.published,
        local: existing.local,
        internal: existing.internal
      }

      _ = Objects.upsert_object(attrs, conflict: :replace)
      :ok
    else
      _ -> :ok
    end
  end

  defp maybe_apply_credential_update(_actor_ap_id, _object, _opts), do: :ok

  defp deliver_update(%Object{} = update_object, _opts) do
    with %User{} = actor <- Users.get_by_ap_id(update_object.actor),
         inboxes when is_list(inboxes) and inboxes != [] <-
           inboxes_for_delivery(update_object, actor) do
      Enum.each(inboxes, fn inbox_url ->
        Delivery.deliver(actor, inbox_url, update_object.data)
      end)
    else
      _ -> :ok
    end
  end

  defp inboxes_for_delivery(%{data: %{} = data} = update_object, %User{} = actor) do
    follower_inboxes =
      if followers_addressed?(data, update_object.actor) do
        actor.ap_id
        |> Relationships.list_follows_to()
        |> Enum.map(fn follow ->
          case Users.get_by_ap_id(follow.actor) do
            %User{local: false, inbox: inbox} when is_binary(inbox) and inbox != "" -> inbox
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    recipient_inboxes =
      data
      |> Egregoros.Recipients.recipient_actor_ids(fields: ["to", "cc"])
      |> Enum.map(fn actor_id ->
        case Users.get_by_ap_id(actor_id) do
          %User{local: false, inbox: inbox} when is_binary(inbox) and inbox != "" -> inbox
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    (follower_inboxes ++ recipient_inboxes)
    |> Enum.uniq()
  end

  defp inboxes_for_delivery(_update_object, _actor), do: []

  defp followers_addressed?(%{} = data, actor_ap_id) when is_binary(actor_ap_id) do
    followers = actor_ap_id <> "/followers"
    to = data |> Map.get("to", []) |> List.wrap()
    cc = data |> Map.get("cc", []) |> List.wrap()
    followers in to or followers in cc
  end

  defp followers_addressed?(_data, _actor_ap_id), do: false

  defp validate_inbox_target(%{} = activity, opts) when is_list(opts) do
    InboxTargeting.validate_addressed_or_followed(opts, activity, Map.get(activity, "actor"))
  end

  defp validate_inbox_target(_activity, _opts), do: :ok

  defp validate_object_namespace(%{"object" => object}, opts)
       when is_list(opts) and is_map(object) do
    validate_object_namespace_id(Map.get(object, "id"), opts)
  end

  defp validate_object_namespace(_activity, _opts), do: :ok

  defp validate_object_namespace_id(id, opts) when is_binary(id) and is_list(opts) do
    if Keyword.get(opts, :local, true) do
      :ok
    else
      if local_ap_id?(id), do: {:error, :local_id}, else: :ok
    end
  end

  defp validate_object_namespace_id(_id, _opts), do: :ok

  defp validate_credential_update(%{"object" => %{} = object}) do
    if TypeNormalizer.primary_type(object) == "VerifiableCredential" do
      credential_id = Map.get(object, "id") || Map.get(object, :id)

      case Objects.get_by_ap_id(credential_id) do
        %Object{data: %{} = existing_data} ->
          case public_update_allowed?(existing_data, object) do
            {:ok, _updated_to, _added_public?} -> :ok
            _ -> {:error, :invalid}
          end

        _ ->
          {:error, :invalid}
      end
    else
      :ok
    end
  end

  defp validate_credential_update(_activity), do: :ok

  defp local_ap_id?(id) when is_binary(id) do
    local_domain =
      Endpoint.url()
      |> URI.parse()
      |> Domain.from_uri()

    case URI.parse(id) do
      %URI{} = uri ->
        case Domain.from_uri(uri) do
          domain when is_binary(local_domain) and is_binary(domain) and domain == local_domain ->
            true

          _ ->
            false
        end

      _ ->
        false
    end
  end

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
    |> Helpers.attach_type_metadata(opts)
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
      # Accept multi-type objects by validating against the primary type only.
      object_type = TypeNormalizer.primary_type(object_value)

      errors =
        if is_binary(object_id) and String.trim(object_id) != "" and is_binary(object_type) and
             String.trim(object_type) != "" do
          []
        else
          [object: "must be an object with id and type"]
        end

      errors =
        cond do
          not is_binary(update_actor) or String.trim(update_actor) == "" ->
            errors

          object_type == "VerifiableCredential" ->
            issuer_id = credential_issuer_id(object_value)

            if is_binary(issuer_id) and issuer_id == update_actor do
              errors
            else
              errors ++ [object: "actor does not match Update actor"]
            end

          object_type in @actor_types and object_id != update_actor ->
            errors ++ [object: "actor does not match Update actor"]

          true ->
            object_actor_ids = extract_object_actor_ids(object_value)

            if object_actor_ids != [] and update_actor not in object_actor_ids do
              errors ++ [object: "actor does not match Update actor"]
            else
              errors
            end
        end

      errors
    end)
  end

  defp extract_object_actor_ids(object) when is_map(object) do
    object
    |> object_author_field()
    |> List.wrap()
    |> Enum.map(&extract_actor_id/1)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp extract_object_actor_ids(_), do: []

  defp object_author_field(%{"attributedTo" => value}), do: value
  defp object_author_field(%{attributedTo: value}), do: value
  defp object_author_field(%{"actor" => value}), do: value
  defp object_author_field(%{actor: value}), do: value
  defp object_author_field(_), do: nil

  defp extract_actor_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_actor_id(%{id: id}) when is_binary(id), do: id
  defp extract_actor_id(id) when is_binary(id), do: id
  defp extract_actor_id(_), do: nil

  defp credential_issuer_id(%{} = object) do
    case Map.get(object, "issuer") || Map.get(object, :issuer) do
      %{"id" => id} when is_binary(id) -> id
      %{id: id} when is_binary(id) -> id
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp credential_issuer_id(_object), do: nil

  defp public_update_allowed?(%{} = existing, %{} = updated) do
    existing_without_to = Map.drop(existing, ["to", :to])
    updated_without_to = Map.drop(updated, ["to", :to])

    if existing_without_to != updated_without_to do
      {:error, :invalid}
    else
      existing_to = normalize_recipients(Map.get(existing, "to") || Map.get(existing, :to))
      updated_to = normalize_recipients(Map.get(updated, "to") || Map.get(updated, :to))

      existing_set = MapSet.new(existing_to)
      updated_set = MapSet.new(updated_to)

      if MapSet.subset?(existing_set, updated_set) do
        added = MapSet.difference(updated_set, existing_set) |> MapSet.to_list()

        if added == [] or added == [@as_public] do
          {:ok, updated_to, @as_public in added}
        else
          {:error, :invalid}
        end
      else
        {:error, :invalid}
      end
    end
  end

  defp public_update_allowed?(_existing, _updated), do: {:error, :invalid}

  defp normalize_recipients(recipients) do
    recipients
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_put_recipients(activity, _field, []), do: activity

  defp maybe_put_recipients(activity, field, recipients)
       when is_map(activity) and is_binary(field) do
    recipients =
      recipients
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if recipients == [] do
      activity
    else
      Map.put(activity, field, recipients)
    end
  end

  defp maybe_put_recipients(activity, _field, _recipients), do: activity
end
