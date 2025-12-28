defmodule EgregorosWeb.ViewModels.Actor do
  @moduledoc false

  alias Egregoros.Domain
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.URL

  def card(nil) do
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

  def card(ap_id) when is_binary(ap_id) do
    case Users.get_by_ap_id(ap_id) do
      %User{} = user ->
        %{
          ap_id: user.ap_id,
          display_name: user.name || user.nickname || ap_id,
          nickname: user.nickname,
          handle: handle(user, ap_id),
          avatar_url: URL.absolute(user.avatar_url, user.ap_id),
          emojis: Map.get(user, :emojis, []),
          local?: user.local
        }

      nil ->
        %{
          ap_id: ap_id,
          display_name: ap_id,
          nickname: nil,
          handle: ap_id,
          avatar_url: nil,
          emojis: [],
          local?: false
        }
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
end
