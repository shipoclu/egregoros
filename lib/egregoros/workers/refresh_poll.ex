defmodule Egregoros.Workers.RefreshPoll do
  @moduledoc """
  Refreshes remote poll data by fetching the latest Question object from its origin.

  Similar to Pleroma's poll refresh mechanism, this worker is triggered when
  viewing a remote poll to ensure vote counts are up-to-date.
  """
  use Oban.Worker,
    queue: :federation_incoming,
    max_attempts: 3,
    unique: [period: 60, keys: [:ap_id]]

  alias Egregoros.Federation.SignedFetch
  alias Egregoros.Activities.Question
  alias Egregoros.Objects.Polls
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.SafeURL
  alias Egregoros.Timeline

  @accept "application/activity+json, application/ld+json"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ap_id" => ap_id}}) when is_binary(ap_id) do
    ap_id = String.trim(ap_id)

    with %Object{type: "Question", local: false} = object <- Objects.get_by_ap_id(ap_id),
         :ok <- SafeURL.validate_http_url_federation(ap_id),
         {:ok, %{status: status, body: body}} <- SignedFetch.get(ap_id, accept: @accept),
         status when status in 200..299 <- status,
         {:ok, %{"type" => "Question"} = question} <- decode_json(body),
         :ok <- validate_id(question, ap_id),
         {:ok, normalized} <- Question.cast_and_validate(question) do
      case Polls.update_from_remote(object, normalized) do
        {:ok, updated} ->
          Timeline.broadcast_post_updated(updated)
          :ok

        :noop ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      # Poll doesn't exist locally or is local - nothing to refresh
      nil ->
        :ok

      %Object{local: true} ->
        :ok

      %Object{type: type} when type != "Question" ->
        :ok

      # HTTP errors - don't retry for client errors
      status when is_integer(status) and status in 400..499 ->
        :ok

      {:ok, %{status: status}} when status in 400..499 ->
        :ok

      # Other errors may be transient
      status when is_integer(status) ->
        {:error, {:http_status, status}}

      {:error, :unsafe_url} ->
        :ok

      {:error, :id_mismatch} ->
        :ok

      {:error, :invalid_json} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      _ ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  @doc """
  Schedules a poll refresh if the poll is remote and still open.
  Returns :ok regardless of whether a job was scheduled.
  """
  def maybe_enqueue(%Object{type: "Question", local: false, ap_id: ap_id, data: data})
      when is_binary(ap_id) do
    if poll_open?(data) do
      %{ap_id: ap_id}
      |> new()
      |> Oban.insert()
    end

    :ok
  end

  def maybe_enqueue(_object), do: :ok

  defp poll_open?(data) when is_map(data) do
    case Map.get(data, "closed") do
      nil ->
        # No end time - poll is open
        true

      closed when is_binary(closed) ->
        case DateTime.from_iso8601(closed) do
          {:ok, end_time, _offset} ->
            DateTime.compare(end_time, DateTime.utc_now()) == :gt

          _ ->
            # Can't parse - assume open
            true
        end

      _ ->
        true
    end
  end

  defp poll_open?(_data), do: true

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_json(_body), do: {:error, :invalid_json}

  defp validate_id(%{"id" => id}, expected) when is_binary(id) and is_binary(expected) do
    if id == expected, do: :ok, else: {:error, :id_mismatch}
  end

  defp validate_id(_map, _expected), do: :ok
end
