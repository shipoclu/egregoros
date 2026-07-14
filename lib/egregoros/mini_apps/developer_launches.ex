defmodule Egregoros.MiniApps.DeveloperLaunches do
  @moduledoc false

  use GenServer

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  @ttl_seconds 15 * 60
  @cleanup_interval_ms 60_000
  @max_entries 1_024

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def put(%User{id: user_id, developer_mode: true}, %ResolvedCard{} = resolved)
      when is_binary(user_id) do
    with true <- origin_allowed?(resolved.app_origin),
         true <- valid_resolved?(resolved) do
      GenServer.call(__MODULE__, {:put, user_id, resolved})
    else
      false -> {:error, :invalid_developer_launch}
    end
  end

  def put(_user, _resolved), do: {:error, :developer_mode_required}

  def get_active(card_id, resolution_token, %User{id: user_id, developer_mode: true})
      when is_binary(card_id) and is_binary(resolution_token) and is_binary(user_id) do
    case GenServer.call(__MODULE__, {:get, card_id, resolution_token, user_id}) do
      %Card{} = card -> if origin_allowed?(card.app_origin), do: card
      nil -> nil
    end
  end

  def get_active(_card_id, _resolution_token, _user), do: nil

  def active?(%Card{developer_user_id: user_id} = card) when is_binary(user_id) do
    case Users.get(user_id) do
      %User{developer_mode: true} = user ->
        match?(%Card{}, get_active(card.id, card.resolution_token, user))

      _ ->
        false
    end
  end

  def active?(_card), do: false

  def launch_info(%Card{developer_user_id: user_id} = card) when is_binary(user_id) do
    %{
      "version" => "1",
      "launchUrl" => card.launch_url,
      "linkedUrl" => card.source_url,
      "sourceNoteId" => Endpoint.url() <> "/developer/mini-apps"
    }
  end

  def launch_info(_card), do: nil

  @impl GenServer
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{cards: %{}, users: %{}}}
  end

  @impl GenServer
  def handle_call({:put, user_id, resolved}, _from, state) do
    state = prune(state)

    case build_card(user_id, resolved) do
      {:ok, card} ->
        state = remove_user_card(state, user_id)

        state = %{
          state
          | cards: Map.put(state.cards, card.id, card),
            users: Map.put(state.users, user_id, card.id)
        }

        {:reply, {:ok, card}, trim_to_limit(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, card_id, resolution_token, user_id}, _from, state) do
    state = prune(state)

    card =
      case Map.get(state.cards, card_id) do
        %Card{developer_user_id: ^user_id, resolution_token: ^resolution_token} = card ->
          card

        _ ->
          nil
      end

    {:reply, card, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    schedule_cleanup()
    {:noreply, prune(state)}
  end

  defp build_card(user_id, %ResolvedCard{} = resolved) do
    now = DateTime.utc_now()
    resolution_token = Ecto.UUID.generate()

    attrs = %{
      object_id: user_id,
      resolution_token: resolution_token,
      source_url: resolved.source_url,
      app_origin: resolved.app_origin,
      app_name: resolved.app_name,
      title: resolved.title,
      button_title: resolved.button_title,
      launch_url: resolved.launch_url,
      image_url: resolved.image_url,
      resolved_at: now,
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    }

    case Card.changeset(%Card{}, attrs) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, card} ->
        {:ok,
         %{
           card
           | id: Ecto.UUID.generate(),
             object_id: nil,
             developer_user_id: user_id
         }}

      {:error, _changeset} ->
        {:error, :invalid_developer_launch}
    end
  end

  defp valid_resolved?(%ResolvedCard{
         app_origin: app_origin,
         source_url: source_url,
         launch_url: launch_url,
         image_url: image_url,
         manifest: %Manifest{origin: app_origin}
       }) do
    Origin.validate_url(source_url, app_origin) == :ok and
      Origin.validate_url(launch_url, app_origin) == :ok and
      (is_nil(image_url) or Origin.validate_url(image_url, app_origin) == :ok)
  end

  defp valid_resolved?(_resolved), do: false

  defp origin_allowed?(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> MiniApps.domain_allowed?(host)
      _ -> false
    end
  end

  defp origin_allowed?(_origin), do: false

  defp prune(state) do
    now = DateTime.utc_now()

    cards =
      Map.reject(state.cards, fn {_id, card} ->
        not DateTime.after?(card.expires_at, now)
      end)

    users = Map.filter(state.users, fn {_user_id, card_id} -> Map.has_key?(cards, card_id) end)
    %{state | cards: cards, users: users}
  end

  defp remove_user_card(state, user_id) do
    case Map.pop(state.users, user_id) do
      {nil, users} -> %{state | users: users}
      {card_id, users} -> %{state | users: users, cards: Map.delete(state.cards, card_id)}
    end
  end

  defp trim_to_limit(state) when map_size(state.cards) <= @max_entries, do: state

  defp trim_to_limit(state) do
    {oldest_id, oldest} =
      Enum.min_by(state.cards, fn {_id, card} ->
        DateTime.to_unix(card.resolved_at, :microsecond)
      end)

    %{
      state
      | cards: Map.delete(state.cards, oldest_id),
        users: Map.delete(state.users, oldest.developer_user_id)
    }
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
