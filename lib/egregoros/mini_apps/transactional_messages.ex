defmodule Egregoros.MiniApps.TransactionalMessages do
  @moduledoc false

  alias Egregoros.ActivityPub.TypeNormalizer
  alias Egregoros.Activities.Note
  alias Egregoros.MiniApps.Declaration
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.NotificationAudits
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Users

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @recipient_fields ~w(to cc bto bcc audience)
  @metadata_key "mini_app_transactional_message"

  def classify_inbound(activity, opts) when is_map(activity) and is_list(opts) do
    if Keyword.get(opts, :local, true) do
      :allow
    else
      classify_remote(activity, opts)
    end
  end

  def classify_inbound(_activity, _opts), do: :allow

  def run_inbound(:allow, callback) when is_function(callback, 1), do: callback.([])
  def run_inbound(:ignore, callback) when is_function(callback, 1), do: {:ok, :ignored}

  def run_inbound({:suppress, authorization, reason}, callback)
      when is_map(authorization) and is_atom(reason) and is_function(callback, 1) do
    suppress(authorization, reason)
  end

  def run_inbound({:authorize, authorization}, callback)
      when is_map(authorization) and is_function(callback, 1) do
    authorize_and_run(authorization, callback)
  end

  def run_inbound(_classification, callback) when is_function(callback, 1),
    do: {:ok, :ignored}

  def attach_object_metadata(attrs, opts) when is_map(attrs) and is_list(opts) do
    case Keyword.get(opts, :mini_app_transaction) do
      %{
        kind: :create,
        origin: origin,
        actor: actor,
        recipient_ap_id: recipient_ap_id
      }
      when is_binary(origin) and is_binary(actor) and is_binary(recipient_ap_id) ->
        marker = %{
          "origin" => origin,
          "actor" => actor,
          "recipient" => recipient_ap_id
        }

        internal = Map.put(Map.get(attrs, :internal, %{}), @metadata_key, marker)
        Map.put(attrs, :internal, internal)

      _ ->
        attrs
    end
  end

  def attach_object_metadata(attrs, _opts), do: attrs

  defp classify_remote(%{"object" => %{} = note} = wrapper, opts) do
    actor = actor_id(Map.get(wrapper, "actor"))

    if TypeNormalizer.primary_type(note) == "Note" and is_binary(actor) do
      case Declarations.activity_pub_declaration_for_actor(actor) do
        {:ok, %Declaration{} = declaration} ->
          if valid_remote_note?(note),
            do: classify_declared(wrapper, note, actor, declaration, opts),
            else: :ignore

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

    cond do
      TypeNormalizer.primary_type(note) != "Note" or not is_binary(actor) ->
        :allow

      actor_id(Keyword.get(opts, :containing_create_actor)) == actor ->
        :allow

      true ->
        classify_bare_note(note, actor)
    end
  end

  defp classify_remote(_activity, _opts), do: :allow

  defp classify_bare_note(note, actor) do
    case Declarations.activity_pub_declaration_for_actor(actor) do
      {:ok, %Declaration{activity_pub_public_notes: true}} ->
        if public?(%{}, note) and not targets_local_user?(%{}, note), do: :allow, else: :ignore

      {:ok, %Declaration{}} ->
        :ignore

      :not_declared ->
        :allow

      {:error, _reason} ->
        :ignore
    end
  end

  defp classify_declared(wrapper, note, actor, declaration, opts) do
    case TypeNormalizer.primary_type(wrapper) do
      "Create" -> classify_declared_create(wrapper, note, actor, declaration, opts)
      "Update" -> classify_declared_update(wrapper, note, actor, declaration, opts)
      _ -> :ignore
    end
  end

  defp classify_declared_create(create, note, actor, declaration, opts) do
    inbox_user = opts |> Keyword.get(:inbox_user_ap_id) |> local_user()

    cond do
      match?(%User{}, inbox_user) and targets_local_user?(create, note) and
        public?(create, %{}) and public?(%{}, note) and
          declaration.activity_pub_public_notes ->
        :allow

      match?(%User{}, inbox_user) and
          (targets_local_user?(create, note) or not public?(create, note)) ->
        classify_transaction(
          create,
          note,
          actor,
          declaration,
          inbox_user,
          :create
        )

      targets_local_user?(create, note) ->
        :ignore

      public?(create, note) and declaration.activity_pub_public_notes ->
        :allow

      true ->
        :ignore
    end
  end

  defp classify_declared_update(update, note, actor, declaration, opts) do
    existing = note |> Map.get("id") |> Objects.get_by_ap_id()

    case protected_transaction_user(existing, actor, declaration.app_origin) do
      %User{} = user ->
        classify_transaction(update, note, actor, declaration, user, :update)

      nil ->
        classify_public_update(existing, update, note, actor, declaration, opts)
    end
  end

  defp classify_public_update(
         %Object{actor: actor, data: existing_data},
         update,
         note,
         actor,
         %Declaration{activity_pub_public_notes: true},
         _opts
       )
       when is_map(existing_data) do
    if public?(%{}, existing_data) and public?(update, note) and
         not targets_local_user?(update, note),
       do: :allow,
       else: :ignore
  end

  defp classify_public_update(_existing, _update, _note, _actor, _declaration, _opts),
    do: :ignore

  defp classify_transaction(wrapper, note, actor, declaration, %User{} = user, kind) do
    authorization = authorization(wrapper, actor, declaration.app_origin, user, kind)

    cond do
      is_nil(authorization) ->
        :ignore

      not declaration.activity_pub_transactional_mentions ->
        {:suppress, authorization, :capability_missing}

      valid_transaction_envelope?(wrapper, note, actor, user.ap_id) ->
        {:authorize, authorization}

      true ->
        {:suppress, authorization, :invalid_envelope}
    end
  end

  defp valid_transaction_envelope?(wrapper, note, actor, recipient_ap_id) do
    recipients = recipient_ids(wrapper) ++ recipient_ids(note)
    mentions = mention_ids(note)

    object_actor(note) == actor and Enum.uniq(recipients) == [recipient_ap_id] and
      mentions == [recipient_ap_id] and not Enum.member?(recipients, @as_public)
  end

  defp authorization(wrapper, actor, origin, %User{} = user, kind) do
    case Map.get(wrapper, "id") do
      activity_id when is_binary(activity_id) and byte_size(activity_id) in 1..2_048 ->
        %{
          activity_id: activity_id,
          actor: actor,
          kind: kind,
          origin: origin,
          recipient_ap_id: user.ap_id,
          user_id: user.id
        }

      _ ->
        nil
    end
  end

  defp protected_transaction_user(
         %Object{actor: actor, internal: internal} = existing,
         actor,
         origin
       ) do
    marker = Map.get(internal || %{}, @metadata_key)

    case marker do
      %{"origin" => ^origin, "actor" => ^actor, "recipient" => recipient_ap_id} ->
        local_user(recipient_ap_id)

      _ ->
        legacy_private_transaction_user(existing)
    end
  end

  defp protected_transaction_user(%Object{}, _actor, _origin), do: nil
  defp protected_transaction_user(nil, _actor, _origin), do: nil

  defp legacy_private_transaction_user(%Object{data: %{} = data}) do
    recipients = recipient_ids(data) |> Enum.uniq()
    mentions = mention_ids(data)

    case recipients do
      [recipient_ap_id] when mentions == [recipient_ap_id] and recipient_ap_id != @as_public ->
        local_user(recipient_ap_id)

      _ ->
        nil
    end
  end

  defp legacy_private_transaction_user(%Object{}), do: nil

  defp authorize_and_run(authorization, callback) do
    transaction_result =
      Repo.transaction(fn ->
        user = lock_and_load_user(authorization)

        cond do
          is_nil(user) ->
            {:ok, :ignored}

          NotificationAudits.delivery_recorded?(
            user,
            authorization.actor,
            authorization.activity_id
          ) ->
            {:ok, :ignored}

          not current_transactional_declaration?(authorization) ->
            suppress_locked(user, authorization, :capability_missing)

          not NotificationConsents.granted?(user.id, authorization.origin) ->
            suppress_locked(user, authorization, :consent_missing)

          not OAuthRegistrations.active_user_grant?(authorization.origin, user.id) ->
            suppress_locked(user, authorization, :oauth_missing)

          true ->
            run_and_audit_locked(user, authorization, callback)
        end
      end)

    unwrap_transaction(transaction_result)
  end

  defp suppress(authorization, reason) do
    transaction_result =
      Repo.transaction(fn ->
        case lock_and_load_user(authorization) do
          %User{} = user ->
            if NotificationAudits.delivery_recorded?(
                 user,
                 authorization.actor,
                 authorization.activity_id
               ) do
              {:ok, :ignored}
            else
              suppress_locked(user, authorization, reason)
            end

          nil ->
            {:ok, :ignored}
        end
      end)

    unwrap_transaction(transaction_result)
  end

  defp lock_and_load_user(authorization) do
    NotificationConsents.lock_delivery(authorization.user_id, authorization.origin)

    case Repo.get(User, authorization.user_id) do
      %User{local: true, ap_id: recipient_ap_id} = user
      when recipient_ap_id == authorization.recipient_ap_id ->
        user

      _ ->
        nil
    end
  end

  defp current_transactional_declaration?(authorization) do
    case Declarations.activity_pub_declaration_for_actor(authorization.actor) do
      {:ok,
       %Declaration{
         app_origin: origin,
         activity_pub_transactional_mentions: true
       }} ->
        origin == authorization.origin

      _ ->
        false
    end
  end

  defp run_and_audit_locked(user, authorization, callback) do
    opts = [mini_app_transaction: authorization]

    case callback.(opts) do
      {:ok, _result} = success ->
        case record_delivery(user, authorization, :delivery_accepted, nil) do
          :ok -> success
          :duplicate -> {:ok, :ignored}
          {:error, reason} -> Repo.rollback({:delivery_result, {:error, reason}})
        end

      {:error, _reason} = error ->
        Repo.rollback({:delivery_result, error})

      _other ->
        Repo.rollback({:delivery_result, {:error, :invalid}})
    end
  end

  defp suppress_locked(user, authorization, reason) do
    case record_delivery(user, authorization, :delivery_suppressed, reason) do
      result when result in [:ok, :duplicate] -> {:ok, :ignored}
      {:error, audit_reason} -> Repo.rollback({:delivery_result, {:error, audit_reason}})
    end
  end

  defp record_delivery(user, authorization, event, reason) do
    NotificationAudits.record_delivery(
      user,
      authorization.origin,
      authorization.actor,
      authorization.activity_id,
      event,
      reason
    )
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, {:delivery_result, result}}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp targets_local_user?(wrapper, note) do
    (recipient_ids(wrapper) ++ recipient_ids(note) ++ mention_ids(note))
    |> Enum.uniq()
    |> Enum.any?(fn
      actor_id when is_binary(actor_id) ->
        match?(%User{local: true}, Users.get_by_ap_id(actor_id))

      _ ->
        false
    end)
  end

  defp public?(wrapper, note) do
    @as_public in recipient_ids(wrapper) or @as_public in recipient_ids(note)
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
    |> Enum.map(&(actor_id(Map.get(&1, "href")) || actor_id(Map.get(&1, "id"))))
  end

  defp mention_ids(_note), do: []

  defp object_actor(%{"attributedTo" => actor}), do: actor_id(actor)
  defp object_actor(%{"actor" => actor}), do: actor_id(actor)
  defp object_actor(_note), do: nil

  defp actor_id(%{"id" => id}) when is_binary(id), do: id
  defp actor_id(id) when is_binary(id), do: id
  defp actor_id(_value), do: nil

  defp valid_remote_note?(note) do
    match?({:ok, %{}}, Note.cast_and_validate(note, local: false))
  end

  defp local_user(actor_id) when is_binary(actor_id) do
    case Users.get_by_ap_id(actor_id) do
      %User{local: true} = user -> user
      _ -> nil
    end
  end

  defp local_user(_actor_id), do: nil
end
