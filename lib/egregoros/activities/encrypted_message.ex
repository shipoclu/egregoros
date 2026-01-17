defmodule Egregoros.Activities.EncryptedMessage do
  alias Egregoros.Activities.Note

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  def type, do: "EncryptedMessage"

  def build(actor, content) when is_binary(actor) and is_binary(content) do
    actor
    |> Note.build(content)
    |> Map.put("type", type())
  end

  def cast_and_validate(object) when is_map(object) do
    note_like =
      object
      |> Map.put("type", "Note")

    with {:ok, validated} <- Note.cast_and_validate(note_like),
         :ok <- validate_e2ee_payload(validated),
         :ok <- validate_direct_only(validated) do
      {:ok, Map.put(validated, "type", type())}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, :missing_e2ee_payload} ->
        {:error,
         %Note{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:content, "missing egregoros:e2ee_dm payload")}

      {:error, :not_direct} ->
        {:error,
         %Note{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:to, "must not be publicly addressed")}

      _ ->
        {:error,
         %Note{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:type, "invalid EncryptedMessage")}
    end
  end

  def cast_and_validate(_object) do
    {:error,
     %Note{}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:type, "invalid EncryptedMessage")}
  end

  def ingest(object, opts) do
    Note.ingest(object, opts)
  end

  def side_effects(object, opts) do
    Note.side_effects(object, opts)
  end

  defp validate_e2ee_payload(%{} = object) do
    case Map.get(object, "egregoros:e2ee_dm") do
      %{} = payload when map_size(payload) > 0 -> :ok
      _ -> {:error, :missing_e2ee_payload}
    end
  end

  defp validate_e2ee_payload(_object), do: {:error, :missing_e2ee_payload}

  defp validate_direct_only(%{"actor" => actor} = object) when is_binary(actor) do
    followers = actor <> "/followers"

    to = object |> Map.get("to", []) |> List.wrap()
    cc = object |> Map.get("cc", []) |> List.wrap()
    audience = object |> Map.get("audience", []) |> List.wrap()

    direct? =
      not (@as_public in to or @as_public in cc or @as_public in audience or followers in to or
             followers in cc)

    if direct?, do: :ok, else: {:error, :not_direct}
  end

  defp validate_direct_only(_object), do: {:error, :not_direct}
end
