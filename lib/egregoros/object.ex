defmodule Egregoros.Object do
  use Ecto.Schema

  import Ecto.Changeset

  @required_fields ~w(ap_id type data)a
  @optional_fields ~w(actor object published local thread_replies_checked_at)a

  schema "objects" do
    field :ap_id, :string
    field :type, :string
    field :actor, :string
    field :object, :string
    field :in_reply_to_ap_id, :string
    field :data, :map
    field :published, :utc_datetime_usec
    field :local, :boolean, default: true
    field :thread_replies_checked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(object, attrs) do
    object
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> put_in_reply_to_ap_id()
    |> unique_constraint(:ap_id)
  end

  defp put_in_reply_to_ap_id(%Ecto.Changeset{} = changeset) do
    type = get_field(changeset, :type)

    in_reply_to_ap_id =
      changeset
      |> get_field(:data)
      |> case do
        %{"inReplyTo" => in_reply_to} -> normalize_in_reply_to_ap_id(in_reply_to)
        _ -> nil
      end

    if type == "Note" and is_binary(in_reply_to_ap_id) and in_reply_to_ap_id != "" do
      put_change(changeset, :in_reply_to_ap_id, in_reply_to_ap_id)
    else
      put_change(changeset, :in_reply_to_ap_id, nil)
    end
  end

  defp normalize_in_reply_to_ap_id(value) when is_binary(value), do: value
  defp normalize_in_reply_to_ap_id(%{"id" => id}) when is_binary(id), do: id
  defp normalize_in_reply_to_ap_id(_), do: nil
end
