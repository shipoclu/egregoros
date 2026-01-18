defmodule Egregoros.Activities.Answer do
  @moduledoc """
  Activity handler for ActivityPub Answer objects (poll votes).

  Answers have:
  - `name`: The text of the chosen poll option
  - `inReplyTo`: The ap_id of the Question being answered
  - `actor`/`attributedTo`: Who voted

  Side effects update the Question's vote count when an Answer is ingested.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Egregoros.Activities.Helpers
  alias Egregoros.ActivityPub.ObjectValidators.Types.ObjectID
  alias Egregoros.ActivityPub.ObjectValidators.Types.Recipients
  alias Egregoros.ActivityPub.ObjectValidators.Types.DateTime, as: APDateTime
  alias Egregoros.Objects

  def type, do: "Answer"

  @primary_key false
  embedded_schema do
    field :id, ObjectID
    field :type, :string
    field :actor, ObjectID
    field :name, :string
    field :inReplyTo, ObjectID
    field :to, Recipients
    field :cc, Recipients
    field :published, APDateTime
  end

  def cast_and_validate(answer) when is_map(answer) do
    answer =
      answer
      |> normalize_actor()
      |> normalize_in_reply_to()

    changeset =
      %__MODULE__{}
      |> cast(answer, __schema__(:fields))
      |> validate_required([:id, :type, :actor, :name, :inReplyTo])
      |> validate_inclusion(:type, [type()])

    case apply_action(changeset, :insert) do
      {:ok, %__MODULE__{} = validated} ->
        {:ok, apply_answer(answer, validated)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  def to_object_attrs(answer, opts) do
    %{
      ap_id: answer["id"],
      type: answer["type"],
      actor: answer["actor"],
      object: answer["inReplyTo"],
      data: answer,
      published: Helpers.parse_datetime(answer["published"]),
      local: Keyword.get(opts, :local, true)
    }
  end

  def ingest(answer, opts) do
    answer
    |> to_object_attrs(opts)
    |> Objects.upsert_object()
  end

  def side_effects(object, _opts) do
    with %{data: %{"inReplyTo" => question_ap_id, "name" => name, "actor" => actor}}
         when is_binary(question_ap_id) and is_binary(name) and is_binary(actor) <- object do
      Objects.increase_vote_count(question_ap_id, name, actor)
    end

    :ok
  end

  # Normalization

  defp apply_answer(answer, %__MODULE__{} = validated) do
    answer
    |> Map.put("id", validated.id)
    |> Map.put("type", validated.type)
    |> Map.put("actor", validated.actor)
    |> Map.put("name", validated.name)
    |> Map.put("inReplyTo", validated.inReplyTo)
    |> Helpers.maybe_put("to", validated.to)
    |> Helpers.maybe_put("cc", validated.cc)
    |> Helpers.maybe_put("published", validated.published)
  end

  defp normalize_actor(%{"actor" => _} = answer), do: answer

  defp normalize_actor(%{"attributedTo" => actor} = answer) do
    Map.put(answer, "actor", actor)
  end

  defp normalize_actor(answer), do: answer

  defp normalize_in_reply_to(%{"inReplyTo" => reply_to} = answer) when is_binary(reply_to) do
    answer
  end

  defp normalize_in_reply_to(%{"inReplyTo" => %{"id" => reply_to}} = answer)
       when is_binary(reply_to) do
    Map.put(answer, "inReplyTo", reply_to)
  end

  defp normalize_in_reply_to(answer), do: answer
end
