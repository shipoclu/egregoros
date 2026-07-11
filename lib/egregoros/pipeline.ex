defmodule Egregoros.Pipeline do
  alias Egregoros.ActivityRegistry
  alias Egregoros.ActivityPub.TypeNormalizer
  alias Egregoros.ActivityPub.ObjectAuthority
  alias Egregoros.Domain
  alias Egregoros.Federation.ActorDiscovery
  alias Egregoros.Federation.ActivityLimits
  alias Egregoros.MiniApps.TransactionalMessages
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Repo
  alias EgregorosWeb.Endpoint

  @effect_key "side_effects"

  def ingest(activity, opts \\ []) when is_map(activity) do
    # Normalize multi-type objects before routing so ActivityRegistry and validations
    # can operate on a single primary type (the canonical multi-type array is restored
    # later when we persist data).
    with {:ok, normalized_activity, type_metadata} <- TypeNormalizer.normalize_incoming(activity),
         opts <- TypeNormalizer.put_type_metadata(opts, type_metadata),
         :ok <- validate_namespace(normalized_activity, opts),
         :ok <- validate_structure(normalized_activity, opts),
         :ok <- validate_authority(normalized_activity, opts),
         {:ok, module} <- ActivityRegistry.fetch(normalized_activity),
         :allow <- TransactionalMessages.classify_inbound(normalized_activity, opts) do
      ingest_with(module, normalized_activity, opts)
    else
      :ignore -> {:ok, :ignored}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def ingest_with(module, activity, opts \\ [])
      when is_atom(module) and is_map(activity) and is_list(opts) do
    with {:ok, validated} <- cast_and_validate(module, activity, opts),
         {:ok, object, run_effects?} <- persist_with_pending_effect(module, validated, opts),
         :ok <- discover_actors(validated, opts) do
      run_side_effects(module, object, opts, run_effects?)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end

  defp discover_actors(activity, opts) when is_map(activity) and is_list(opts) do
    ActorDiscovery.enqueue(activity, opts)
  end

  defp validate_structure(activity, opts) do
    if Keyword.get(opts, :local, true), do: :ok, else: ActivityLimits.validate(activity)
  end

  defp persist_with_pending_effect(module, activity, opts) do
    case Repo.transaction(fn ->
           case module.ingest(activity, opts) do
             {:ok, %Object{} = object} -> mark_effect_pending(object, module)
             {:ok, object} -> {object, true}
             {:error, reason} -> Repo.rollback(reason)
             _ -> Repo.rollback(:invalid)
           end
         end) do
      {:ok, {object, run_effects?}} -> {:ok, object, run_effects?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_effect_pending(%Object{} = object, module) do
    module_name = Atom.to_string(module)
    effect = get_in(object.internal || %{}, ["pipeline", @effect_key])

    if match?(%{"module" => ^module_name, "state" => "completed"}, effect) do
      {object, false}
    else
      attempts =
        case effect do
          %{"attempts" => attempts} when is_integer(attempts) and attempts >= 0 -> attempts + 1
          _ -> 1
        end

      internal =
        put_effect(object.internal, %{
          "module" => module_name,
          "state" => "pending",
          "attempts" => attempts
        })

      case Objects.update_object(object, %{internal: internal}) do
        {:ok, %Object{} = updated} -> {updated, true}
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp run_side_effects(_module, %Object{} = object, _opts, false), do: {:ok, object}

  defp run_side_effects(module, %Object{} = object, opts, true) do
    case module.side_effects(object, opts) do
      :ok ->
        with {:ok, _completed} <- mark_effect_completed(object, module), do: {:ok, object}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :invalid}
    end
  end

  defp run_side_effects(module, object, opts, true) do
    case module.side_effects(object, opts) do
      :ok -> {:ok, object}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid}
    end
  end

  defp mark_effect_completed(%Object{} = object, module) do
    current = Objects.get_by_ap_id(object.ap_id) || object
    module_name = Atom.to_string(module)

    effect =
      (current.internal || %{})
      |> get_in(["pipeline", @effect_key])
      |> case do
        %{} = effect -> effect
        _ -> %{}
      end
      |> Map.merge(%{
        "module" => module_name,
        "state" => "completed",
        "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    internal = put_effect(current.internal, effect)

    case Objects.update_object(current, %{internal: internal}) do
      {:ok, %Object{} = updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_effect(internal, effect) do
    internal = if is_map(internal), do: internal, else: %{}
    pipeline = if is_map(internal["pipeline"]), do: internal["pipeline"], else: %{}
    pipeline = Map.put(pipeline, @effect_key, effect)
    Map.put(internal, "pipeline", pipeline)
  end

  defp cast_and_validate(module, activity, opts) do
    _ = Code.ensure_loaded(module)

    # Prefer cast_and_validate/2 if available (allows passing opts for inbox targeting)
    # Fall back to cast_and_validate/1 for backwards compatibility
    result =
      cond do
        function_exported?(module, :cast_and_validate, 2) ->
          module.cast_and_validate(activity, opts)

        function_exported?(module, :cast_and_validate, 1) ->
          module.cast_and_validate(activity)

        true ->
          {:error, :invalid}
      end

    case result do
      {:ok, validated} when is_map(validated) -> {:ok, validated}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid}
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end

  defp validate_namespace(activity, opts) when is_map(activity) and is_list(opts) do
    if Keyword.get(opts, :local, true) do
      :ok
    else
      case extract_id(activity) do
        id when is_binary(id) and id != "" ->
          if local_ap_id?(id), do: {:error, :local_id}, else: :ok

        _ ->
          :ok
      end
    end
  end

  defp validate_namespace(_activity, _opts), do: :ok

  defp validate_authority(activity, opts) when is_map(activity) and is_list(opts) do
    if Keyword.get(opts, :local, true), do: :ok, else: ObjectAuthority.validate(activity)
  end

  defp extract_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_id(%{id: id}) when is_binary(id), do: id
  defp extract_id(_activity), do: nil

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
end
