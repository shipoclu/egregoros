defmodule EgregorosWeb.ViewModels.Actor do
  @moduledoc false

  alias Egregoros.Domain
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.URL

  def cards_by_ap_id(ap_ids) when is_list(ap_ids) do
    ap_ids = normalize_ap_ids(ap_ids)

    users_by_ap_id =
      ap_ids
      |> Users.list_by_ap_ids()
      |> Map.new(&{&1.ap_id, &1})

    Enum.reduce(ap_ids, %{}, fn ap_id, acc ->
      card =
        case Map.get(users_by_ap_id, ap_id) do
          %User{} = user -> card_from_user(user, ap_id)
          _ -> fallback_card(ap_id)
        end

      Map.put(acc, ap_id, card)
    end)
  end

  def cards_by_ap_id(_ap_ids), do: %{}

  def card(nil) do
    unknown_card()
  end

  def card(ap_id) when is_binary(ap_id) do
    ap_id = String.trim(ap_id)

    if ap_id == "" do
      unknown_card()
    else
      case Users.get_by_ap_id(ap_id) do
        %User{} = user -> card_from_user(user, ap_id)
        nil -> fallback_card(ap_id)
      end
    end
  end

  def handle(%User{nickname: nickname, local: true}, _ap_id)
      when is_binary(nickname) and nickname != "" do
    "@" <> nickname
  end

  def handle(%User{nickname: nickname}, ap_id)
      when is_binary(nickname) and nickname != "" and is_binary(ap_id) do
    case URI.parse(ap_id) do
      %URI{} = uri ->
        case Domain.from_uri(uri) do
          domain when is_binary(domain) and domain != "" -> "@#{nickname}@#{domain}"
          _ -> "@" <> nickname
        end

      _ ->
        "@" <> nickname
    end
  end

  def handle(_user, ap_id) when is_binary(ap_id), do: ap_id
  def handle(_user, _ap_id), do: "@unknown"

  defp normalize_ap_ids(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_ap_ids(_), do: []

  defp card_from_user(%User{} = user, ap_id) when is_binary(ap_id) do
    %{
      ap_id: user.ap_id,
      display_name: user.name || user.nickname || ap_id,
      nickname: user.nickname,
      handle: handle(user, ap_id),
      avatar_url: URL.absolute(user.avatar_url, user.ap_id),
      emojis: Map.get(user, :emojis, []),
      local?: user.local
    }
  end

  defp fallback_card(ap_id) when is_binary(ap_id) do
    {nickname, domain} = derive_handle_parts(ap_id)

    %{
      ap_id: ap_id,
      display_name: nickname || ap_id,
      nickname: nickname,
      handle: derive_handle(nickname, domain, ap_id),
      avatar_url: nil,
      emojis: [],
      local?: false
    }
  end

  defp unknown_card do
    %{
      ap_id: nil,
      display_name: "Unknown",
      nickname: nil,
      handle: "@unknown",
      avatar_url: nil,
      emojis: [],
      local?: false
    }
  end

  defp derive_handle_parts(ap_id) when is_binary(ap_id) do
    ap_id = String.trim(ap_id)

    with %URI{} = uri <- URI.parse(ap_id),
         host when is_binary(host) <- uri.host,
         host when host != "" <- String.trim(host) do
      domain = Domain.from_uri(uri)

      nickname =
        uri.path
        |> Kernel.||("")
        |> String.split("/", trim: true)
        |> List.last()
        |> candidate_nickname()

      nickname =
        case nickname do
          value when is_binary(value) ->
            value = String.trim(value)
            if value == "", do: nil, else: value

          _ ->
            nil
        end

      {nickname, domain}
    else
      _ -> {nil, nil}
    end
  end

  @fallback_nickname_blocklist ~w(users user actor objects object inbox outbox followers following)

  defp candidate_nickname("@" <> nick), do: candidate_nickname(nick)

  defp candidate_nickname(nick) when is_binary(nick) do
    nick = String.trim(nick)

    cond do
      nick == "" ->
        nil

      nick in @fallback_nickname_blocklist ->
        nil

      Regex.match?(~r/^[\p{L}\p{N}_][\p{L}\p{N}_.-]{0,63}$/u, nick) ->
        nick

      true ->
        nil
    end
  end

  defp candidate_nickname(_), do: nil

  defp derive_handle(nickname, domain, fallback_ap_id)
       when is_binary(fallback_ap_id) do
    cond do
      is_binary(nickname) and nickname != "" and is_binary(domain) and domain != "" ->
        "@#{nickname}@#{domain}"

      is_binary(nickname) and nickname != "" ->
        "@#{nickname}"

      true ->
        fallback_ap_id
    end
  end
end
