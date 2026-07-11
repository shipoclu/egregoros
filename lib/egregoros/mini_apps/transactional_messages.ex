defmodule Egregoros.MiniApps.TransactionalMessages do
  @moduledoc false

  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.NotificationAudits
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.ActivityPub.TypeNormalizer
  alias Egregoros.User
  alias Egregoros.Users

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @recipient_fields ~w(to cc bto bcc audience)

  def classify_inbound(activity, opts) when is_map(activity) and is_list(opts) do
    if Keyword.get(opts, :local, true) do
      :allow
    else
      classify_remote(activity, opts)
    end
  end

  def classify_inbound(_activity, _opts), do: :allow

  defp classify_remote(%{"actor" => actor, "object" => %{} = note} = create, opts)
       when is_binary(actor) do
    if TypeNormalizer.primary_type(note) == "Note" do
      case Declarations.notification_origin_for_actor(actor) do
        {:ok, origin} ->
          if TypeNormalizer.primary_type(create) == "Create" do
            classify_declared(create, note, actor, origin, opts)
          else
            classify_non_create_note(create, note)
          end

        :not_declared ->
          :allow

        {:error, _reason} ->
          :ignore
      end
    else
      :allow
    end
  end

  defp classify_remote(%{} = note, opts) do
    actor = object_actor(note)

    if Keyword.get(opts, :containing_create_actor) == actor do
      :allow
    else
      classify_bare_note(note, actor)
    end
  end

  defp classify_remote(_activity, _opts), do: :allow

  defp classify_bare_note(note, actor) do
    if TypeNormalizer.primary_type(note) == "Note" and is_binary(actor) do
      case Declarations.notification_origin_for_actor(actor) do
        {:ok, _origin} ->
          if targets_local_user?(%{}, note) or not public?(%{}, note), do: :ignore, else: :allow

        :not_declared ->
          :allow

        {:error, _reason} ->
          :ignore
      end
    else
      :allow
    end
  end

  defp classify_declared(create, note, actor, origin, opts) do
    inbox_user = opts |> Keyword.get(:inbox_user_ap_id) |> local_user()

    cond do
      match?(%User{}, inbox_user) ->
        authorize_transaction(create, note, actor, origin, inbox_user)

      targets_local_user?(create, note) ->
        :ignore

      public?(create, note) ->
        :allow

      true ->
        :ignore
    end
  end

  defp classify_non_create_note(wrapper, note) do
    if targets_local_user?(wrapper, note) or not public?(wrapper, note),
      do: :ignore,
      else: :allow
  end

  defp authorize_transaction(create, note, actor, origin, %User{} = user) do
    recipients = recipient_ids(create) ++ recipient_ids(note)
    mentions = mention_ids(note)

    valid_envelope? =
      object_actor(note) == actor and Enum.uniq(recipients) == [user.ap_id] and
        mentions == [user.ap_id] and not Enum.member?(recipients, @as_public)

    cond do
      not valid_envelope? ->
        audit_delivery(user, origin, actor, :delivery_suppressed, :invalid_envelope)
        :ignore

      not NotificationConsents.granted?(user.id, origin) ->
        audit_delivery(user, origin, actor, :delivery_suppressed, :consent_missing)
        :ignore

      not OAuthRegistrations.active_user_grant?(origin, user.id) ->
        audit_delivery(user, origin, actor, :delivery_suppressed, :oauth_missing)
        :ignore

      true ->
        audit_delivery(user, origin, actor, :delivery_accepted, nil)
        :allow
    end
  end

  defp audit_delivery(user, origin, actor, event, reason) do
    _ = NotificationAudits.record(user, origin, actor, event, reason)
    :ok
  end

  defp targets_local_user?(create, note) do
    (recipient_ids(create) ++ recipient_ids(note) ++ mention_ids(note))
    |> Enum.uniq()
    |> Enum.any?(fn
      actor_id when is_binary(actor_id) ->
        match?(%User{local: true}, Users.get_by_ap_id(actor_id))

      _ ->
        false
    end)
  end

  defp public?(create, note) do
    @as_public in recipient_ids(create) or @as_public in recipient_ids(note)
  end

  defp recipient_ids(value) when is_map(value) do
    Enum.flat_map(@recipient_fields, fn field ->
      value
      |> Map.get(field, [])
      |> List.wrap()
      |> Enum.map(&actor_id/1)
    end)
  end

  defp recipient_ids(_value), do: []

  defp mention_ids(%{} = note) do
    note
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "Mention"))
    |> Enum.map(&(Map.get(&1, "href") || Map.get(&1, "id")))
  end

  defp mention_ids(_note), do: []

  defp object_actor(%{"attributedTo" => actor}) when is_binary(actor), do: actor
  defp object_actor(%{"actor" => actor}) when is_binary(actor), do: actor
  defp object_actor(_note), do: nil

  defp actor_id(%{"id" => id}) when is_binary(id), do: id
  defp actor_id(id) when is_binary(id), do: id
  defp actor_id(_value), do: :invalid

  defp local_user(actor_id) when is_binary(actor_id) do
    case Users.get_by_ap_id(actor_id) do
      %User{local: true} = user -> user
      _ -> nil
    end
  end

  defp local_user(_actor_id), do: nil
end
