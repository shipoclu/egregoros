defmodule Egregoros.Workers.ResolveMiniAppCard do
  use Oban.Worker,
    queue: :mini_apps,
    max_attempts: 3,
    unique: [period: 60, keys: [:object_id]]

  import Ecto.Query

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.Discovery
  alias Egregoros.Object
  alias Egregoros.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"object_id" => object_id} = args}) when is_binary(object_id) do
    case get_object(object_id) do
      nil ->
        :ok

      %Object{} = object ->
        if expected_resolution?(object, Map.get(args, "resolution_token")) do
          resolve(object)
        else
          :ok
        end
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  def maybe_enqueue(%Object{id: object_id} = object) when not is_nil(object_id) do
    candidates = Discovery.candidate_urls(object)

    cond do
      not MiniApps.enabled?() ->
        log_lookup_skipped(object_id, :disabled)
        Cards.delete(object)

      candidates == [] ->
        log_lookup_skipped(object_id, :no_candidates)
        Cards.delete(object)

      true ->
        invalidate_changed_source(object, candidates)
        enqueue(object_id, %{})

        Logger.debug(
          "miniapp card lookup enqueued object_id=#{inspect(object_id)} candidate_count=#{length(candidates)}"
        )
    end

    :ok
  end

  def maybe_enqueue(%Object{}), do: :ok

  def maybe_enqueue_refresh(%Card{object_id: object_id, resolution_token: resolution_token})
      when not is_nil(object_id) and is_binary(resolution_token) do
    if MiniApps.enabled?() do
      enqueue(object_id, %{"resolution_token" => resolution_token})
    end

    :ok
  end

  def maybe_enqueue_refresh(%Card{}), do: :ok

  defp resolve(object, revision_retries \\ 1) do
    candidates = Discovery.candidate_urls(object)

    cond do
      not MiniApps.enabled?() ->
        log_lookup_skipped(object.id, :disabled)
        Cards.delete(object)

      candidates == [] ->
        log_lookup_skipped(object.id, :no_candidates)
        Cards.delete(object)

      true ->
        Logger.debug(
          "miniapp card resolution started object_id=#{inspect(object.id)} " <>
            "candidate_count=#{length(candidates)}"
        )

        invalidate_changed_source(object, candidates)

        case MiniApps.resolve_note(object) do
          {:ok, resolved} ->
            case put_if_current(object, resolved) do
              {:ok, _card} ->
                Logger.debug(
                  "miniapp card resolution stored object_id=#{inspect(object.id)} " <>
                    "app_origin=#{inspect(resolved.app_origin)}"
                )

                :ok

              {:stale, current} when revision_retries > 0 ->
                resolve(current, revision_retries - 1)

              {:stale, _current} ->
                {:error, :object_changed}

              :missing ->
                :ok

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} when reason in [:disabled, :no_mini_app] ->
            Logger.debug(
              "miniapp card resolution did not find a miniapp " <>
                "object_id=#{inspect(object.id)} reason=#{inspect(reason)}"
            )

            Cards.delete(object)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp expected_resolution?(_object, nil), do: true

  defp expected_resolution?(object, resolution_token) when is_binary(resolution_token) do
    match?(%Card{resolution_token: ^resolution_token}, Cards.get_cached(object))
  end

  defp expected_resolution?(_object, _resolution_token), do: false

  defp log_lookup_skipped(object_id, reason) do
    Logger.debug(
      "miniapp card lookup skipped object_id=#{inspect(object_id)} reason=#{inspect(reason)}"
    )
  end

  defp invalidate_changed_source(object, candidates) do
    case Cards.get_cached(object) do
      %Card{source_url: source_url} ->
        if source_url not in candidates, do: Cards.delete(object)

      _ ->
        :ok
    end
  end

  defp enqueue(object_id, extra_args) do
    %{"object_id" => object_id}
    |> Map.merge(extra_args)
    |> new()
    |> Oban.insert()
  end

  defp put_if_current(object, resolved) do
    Repo.transaction(fn ->
      current =
        from(stored in Object,
          where: stored.id == ^object.id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      cond do
        is_nil(current) -> {:missing, nil}
        same_object_revision?(current, object) -> {:current, Cards.put(current, resolved)}
        true -> {:stale, current}
      end
    end)
    |> case do
      {:ok, {:current, result}} -> result
      {:ok, {:stale, current}} -> {:stale, current}
      {:ok, {:missing, nil}} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_object_revision?(current, loaded) do
    current.updated_at == loaded.updated_at and current.type == loaded.type and
      current.data == loaded.data and current.local == loaded.local and
      current.actor == loaded.actor and current.ap_id == loaded.ap_id
  end

  defp get_object(object_id) do
    Repo.get(Object, object_id)
  rescue
    Ecto.Query.CastError -> nil
    ArgumentError -> nil
  end
end
