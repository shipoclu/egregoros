defmodule Egregoros.Badges do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.Activities.Offer
  alias Egregoros.Activities.VerifiableCredential
  alias Egregoros.BadgeDefinition
  alias Egregoros.Federation.Actor
  alias Egregoros.Federation.Delivery
  alias Egregoros.Federation.InstanceActor
  alias Egregoros.Object
  alias Egregoros.Pipeline
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Users

  def list_definitions(opts \\ []) when is_list(opts) do
    include_disabled? = Keyword.get(opts, :include_disabled?, true)

    BadgeDefinition
    |> maybe_filter_disabled(include_disabled?)
    |> then(fn query -> from(b in query, order_by: [asc: b.name]) end)
    |> Repo.all()
  end

  def issue_badge(badge_type, recipient_ap_id, opts \\ [])

  def issue_badge(badge_type, recipient_ap_id, opts)
      when is_binary(badge_type) and is_binary(recipient_ap_id) and is_list(opts) do
    badge_type = String.trim(badge_type)
    recipient_ap_id = String.trim(recipient_ap_id)

    with %BadgeDefinition{} = badge <- Repo.get_by(BadgeDefinition, badge_type: badge_type),
         :ok <- ensure_enabled(badge),
         {:ok, %User{} = issuer} <- InstanceActor.get_actor(),
         {:ok, %User{} = recipient} <- resolve_recipient(recipient_ap_id),
         {:ok, %Object{} = credential} <- create_credential(badge, issuer, recipient, opts),
         {:ok, %Object{} = offer} <- create_offer(issuer, recipient, credential, opts) do
      {:ok, %{offer: offer, credential: credential, badge: badge, recipient: recipient}}
    else
      nil -> {:error, :unknown_badge}
      {:error, _} = error -> error
      _ -> {:error, :invalid_badge}
    end
  end

  def issue_badge(_badge_type, _recipient_ap_id, _opts), do: {:error, :invalid_badge}

  defp maybe_filter_disabled(query, true), do: query

  defp maybe_filter_disabled(query, false) do
    from(b in query, where: b.disabled == false)
  end

  defp ensure_enabled(%BadgeDefinition{disabled: true}), do: {:error, :disabled_badge}
  defp ensure_enabled(%BadgeDefinition{}), do: :ok

  defp resolve_recipient(ap_id) when is_binary(ap_id) do
    ap_id = String.trim(ap_id)

    cond do
      ap_id == "" ->
        {:error, :invalid_recipient}

      true ->
        case Users.get_by_ap_id(ap_id) do
          %User{} = user -> {:ok, user}
          _ -> Actor.fetch_and_store(ap_id)
        end
    end
  end

  defp resolve_recipient(_ap_id), do: {:error, :invalid_recipient}

  defp create_credential(%BadgeDefinition{} = badge, %User{} = issuer, %User{} = recipient, opts) do
    credential =
      VerifiableCredential.build_for_badge(
        badge,
        issuer.ap_id,
        recipient.ap_id,
        opts
      )

    Pipeline.ingest(credential,
      local: true,
      allow_remote_recipient: true,
      skip_inbox_target: true
    )
  end

  defp create_offer(%User{} = issuer, %User{} = recipient, %Object{} = credential, opts) do
    offer =
      Offer.build(issuer, credential)
      |> Map.put("to", [recipient.ap_id])

    with {:ok, %Object{} = offer_object} <-
           Pipeline.ingest(offer, local: true, skip_inbox_target: true),
         :ok <- maybe_deliver_offer(issuer, recipient, offer_object, credential, opts) do
      {:ok, offer_object}
    end
  end

  defp maybe_deliver_offer(%User{}, %User{local: true}, _offer, _credential, _opts), do: :ok

  defp maybe_deliver_offer(
         %User{} = issuer,
         %User{} = recipient,
         %Object{} = offer,
         %Object{} = credential,
         _opts
       ) do
    inbox = recipient.inbox |> to_string() |> String.trim()

    if inbox == "" do
      {:error, :invalid_recipient}
    else
      payload = Map.put(offer.data, "object", credential.data)

      case Delivery.deliver(issuer, inbox, payload) do
        {:ok, _job} -> :ok
        {:error, _} = error -> error
      end
    end
  end
end
