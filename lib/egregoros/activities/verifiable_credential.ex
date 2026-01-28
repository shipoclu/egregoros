defmodule Egregoros.Activities.VerifiableCredential do
  use Ecto.Schema

  import Ecto.Changeset

  alias Egregoros.Activities.Helpers
  alias Egregoros.ActivityPub.ObjectValidators.Types.DateTime, as: APDateTime
  alias Egregoros.ActivityPub.ObjectValidators.Types.ObjectID
  alias Egregoros.ActivityPub.ObjectValidators.Types.Recipients
  alias Egregoros.InboxTargeting
  alias Egregoros.Objects
  alias Egregoros.SafeURL
  alias Egregoros.User
  alias Egregoros.Users

  def type, do: "VerifiableCredential"

  @primary_key false
  embedded_schema do
    field :id, ObjectID
    field :type, :string
    field :issuer, ObjectID
    field :to, Recipients
    field :cc, Recipients
    field :validFrom, APDateTime
    field :validUntil, APDateTime
  end

  def cast_and_validate(object) when is_map(object) do
    changeset =
      %__MODULE__{}
      |> cast(object, __schema__(:fields))
      |> validate_required([:id, :type, :issuer])
      |> validate_inclusion(:type, [type()])
      |> validate_issuer()
      |> validate_recipient(object)

    # TODO: Verify the embedded proof; we skip it for now because we do not yet support
    # elliptic curve instance actor keys.
    case apply_action(changeset, :insert) do
      {:ok, %__MODULE__{} = credential} -> {:ok, apply_credential(object, credential)}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  def ingest(object, opts) do
    with :ok <- validate_inbox_target(object, opts) do
      object
      |> to_object_attrs(opts)
      |> Objects.upsert_object()
    end
  end

  def side_effects(_object, _opts), do: :ok

  defp validate_inbox_target(%{} = object, opts) when is_list(opts) do
    InboxTargeting.validate_addressed_or_followed(
      opts,
      object,
      issuer_ap_id(object)
    )
  end

  defp validate_inbox_target(_object, _opts), do: :ok

  defp to_object_attrs(object, opts) do
    %{
      ap_id: object["id"],
      type: object["type"],
      actor: issuer_ap_id(object),
      object: nil,
      data: object,
      published: Helpers.parse_datetime(object["validFrom"]),
      local: Keyword.get(opts, :local, true)
    }
    # Preserve multi-type credentials by restoring the canonical type array
    # while still storing a single primary type in the database column.
    |> Helpers.attach_type_metadata(opts)
  end

  defp apply_credential(object, %__MODULE__{} = credential) do
    object
    |> Map.put("id", credential.id)
    |> Map.put("type", credential.type)
    |> Map.put("issuer", credential.issuer)
    |> Helpers.maybe_put("to", credential.to)
    |> Helpers.maybe_put("cc", credential.cc)
    |> Helpers.maybe_put("validFrom", credential.validFrom)
    |> Helpers.maybe_put("validUntil", credential.validUntil)
  end

  defp issuer_ap_id(%{"issuer" => %{"id" => id}}) when is_binary(id), do: id
  defp issuer_ap_id(%{"issuer" => id}) when is_binary(id), do: id
  defp issuer_ap_id(_object), do: nil

  defp recipient_ap_id(%{"credentialSubject" => subject}) do
    subject
    |> List.wrap()
    |> Enum.find_value(fn
      %{"id" => id} when is_binary(id) -> id
      %{id: id} when is_binary(id) -> id
      id when is_binary(id) -> id
      _ -> nil
    end)
  end

  defp recipient_ap_id(_object), do: nil

  defp validate_issuer(changeset) do
    issuer = get_field(changeset, :issuer)
    issuer = if is_binary(issuer), do: String.trim(issuer), else: issuer
    user = Users.get_by_ap_id(issuer)

    cond do
      not is_binary(issuer) or issuer == "" ->
        add_error(changeset, :issuer, "must be a valid actor id")

      match?(%User{}, user) ->
        changeset

      SafeURL.validate_http_url_federation(issuer) == :ok ->
        changeset

      true ->
        add_error(changeset, :issuer, "must be a valid actor id")
    end
  end

  defp validate_recipient(changeset, object) do
    recipient = recipient_ap_id(object)
    recipient = if is_binary(recipient), do: String.trim(recipient), else: recipient
    user = Users.get_by_ap_id(recipient)

    cond do
      not is_binary(recipient) or recipient == "" ->
        add_error(changeset, :credentialSubject, "must include a recipient id")

      match?(%User{local: true}, user) ->
        changeset

      match?(%User{}, user) ->
        add_error(changeset, :credentialSubject, "recipient must be local")

      SafeURL.validate_http_url_federation(recipient) == :ok ->
        add_error(changeset, :credentialSubject, "recipient must be local")

      true ->
        add_error(changeset, :credentialSubject, "recipient must be a valid actor id")
    end
  end
end
