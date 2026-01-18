defmodule Egregoros.Activities.Question do
  @moduledoc """
  Activity handler for ActivityPub Question objects (polls).

  Questions have poll options stored in `oneOf` (single choice) or `anyOf` (multiple choice).
  Each option has a `name` and a `replies.totalItems` count for votes.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Egregoros.Activities.Helpers
  alias Egregoros.Activities.Validations
  alias Egregoros.ActivityPub.ObjectValidators.Types.ObjectID
  alias Egregoros.ActivityPub.ObjectValidators.Types.Recipients
  alias Egregoros.ActivityPub.ObjectValidators.Types.DateTime, as: APDateTime
  alias Egregoros.InboxTargeting
  alias Egregoros.Objects
  alias Egregoros.Timeline

  def type, do: "Question"

  @primary_key false
  embedded_schema do
    field :id, ObjectID
    field :type, :string
    field :actor, ObjectID
    field :attributedTo, ObjectID
    field :context, :string
    field :content, :string
    field :to, Recipients
    field :cc, Recipients
    field :published, APDateTime
    field :closed, APDateTime
  end

  def cast_and_validate(question) when is_map(question) do
    question =
      question
      |> normalize_actor()
      |> normalize_content_map()
      |> normalize_closed()
      |> Map.put_new("content", "")

    changeset =
      %__MODULE__{}
      |> cast(question, __schema__(:fields))
      |> validate_required([:id, :type, :actor, :attributedTo, :context])
      |> validate_inclusion(:type, [type()])
      |> Validations.validate_any_presence([:to, :cc])
      |> Validations.validate_fields_match([:actor, :attributedTo])
      |> Validations.validate_host_match([:id, :actor, :attributedTo])
      |> validate_poll_options(question)

    case apply_action(changeset, :insert) do
      {:ok, %__MODULE__{} = validated} ->
        {:ok, apply_question(question, validated)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  def to_object_attrs(question, opts) do
    %{
      ap_id: question["id"],
      type: question["type"],
      actor: question["actor"],
      object: nil,
      data: question,
      published: Helpers.parse_datetime(question["published"]),
      local: Keyword.get(opts, :local, true)
    }
  end

  def ingest(question, opts) do
    with :ok <- validate_inbox_target(question, opts) do
      conflict = Keyword.get(opts, :conflict, :nothing)

      question
      |> to_object_attrs(opts)
      |> Objects.upsert_object(conflict: conflict)
    end
  end

  def side_effects(object, _opts) do
    Timeline.broadcast_post(object)
    :ok
  end

  # Validation

  defp validate_poll_options(changeset, question) do
    one_of = Map.get(question, "oneOf") |> List.wrap()
    any_of = Map.get(question, "anyOf") |> List.wrap()

    cond do
      valid_options?(one_of) -> changeset
      valid_options?(any_of) -> changeset
      true -> add_error(changeset, :base, "Question must have oneOf or anyOf with valid options")
    end
  end

  defp valid_options?(options) when is_list(options) do
    options != [] and Enum.all?(options, &valid_option?/1)
  end

  defp valid_options?(_), do: false

  defp valid_option?(%{"name" => name}) when is_binary(name) and name != "", do: true
  defp valid_option?(_), do: false

  # Normalization

  defp apply_question(question, %__MODULE__{} = validated) do
    question
    |> Map.put("id", validated.id)
    |> Map.put("type", validated.type)
    |> Map.put("actor", validated.actor)
    |> Helpers.maybe_put("attributedTo", validated.attributedTo)
    |> Helpers.maybe_put("context", validated.context)
    |> Map.put("content", validated.content || Map.get(question, "content", ""))
    |> Helpers.maybe_put("to", validated.to)
    |> Helpers.maybe_put("cc", validated.cc)
    |> Helpers.maybe_put("published", validated.published)
    |> Helpers.maybe_put("closed", validated.closed)
    |> normalize_poll_options()
  end

  defp normalize_actor(%{"actor" => _} = question), do: question

  defp normalize_actor(%{"attributedTo" => actor} = question) do
    Map.put(question, "actor", actor)
  end

  defp normalize_actor(question), do: question

  defp normalize_content_map(%{"content" => content} = question) when is_binary(content) do
    if String.trim(content) == "" do
      do_normalize_content_map(question)
    else
      question
    end
  end

  defp normalize_content_map(question), do: do_normalize_content_map(question)

  defp do_normalize_content_map(%{"contentMap" => content_map} = question)
       when is_map(content_map) do
    case content_from_map(content_map) do
      content when is_binary(content) -> Map.put(question, "content", content)
      _ -> question
    end
  end

  defp do_normalize_content_map(question), do: question

  defp content_from_map(%{} = content_map) do
    preferred = ["en", "und"]

    Enum.find_value(preferred, fn key ->
      case Map.get(content_map, key) do
        "" <> _ = content ->
          content = String.trim(content)
          if content != "", do: content

        _ ->
          nil
      end
    end) ||
      content_map
      |> Enum.filter(fn {key, content} -> is_binary(key) and is_binary(content) end)
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.find_value(fn {_key, content} ->
        content = String.trim(content)
        if content != "", do: content
      end)
  end

  defp normalize_closed(%{"closed" => closed} = question) when is_binary(closed), do: question

  defp normalize_closed(%{"endTime" => end_time} = question) when is_binary(end_time) do
    Map.put(question, "closed", end_time)
  end

  defp normalize_closed(question), do: question

  defp normalize_poll_options(question) do
    question
    |> maybe_normalize_options("oneOf")
    |> maybe_normalize_options("anyOf")
  end

  defp maybe_normalize_options(question, key) do
    case Map.get(question, key) do
      options when is_list(options) and options != [] ->
        normalized = Enum.map(options, &normalize_option/1)
        Map.put(question, key, normalized)

      _ ->
        question
    end
  end

  defp normalize_option(%{"name" => _} = option) do
    option
    |> Map.put_new("type", "Note")
    |> ensure_replies_count()
  end

  defp normalize_option(option), do: option

  defp ensure_replies_count(%{"replies" => %{"totalItems" => count}} = option)
       when is_integer(count) do
    option
  end

  defp ensure_replies_count(option) do
    replies = Map.get(option, "replies", %{})
    total = Map.get(replies, "totalItems", 0)

    Map.put(option, "replies", %{
      "type" => "Collection",
      "totalItems" => if(is_integer(total), do: total, else: 0)
    })
  end

  # Inbox targeting

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
end
