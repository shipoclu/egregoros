defmodule PleromaReduxWeb.ProfilePaths do
  @moduledoc false

  alias PleromaRedux.User

  def profile_path(%User{nickname: nickname, local: true})
      when is_binary(nickname) and nickname != "" do
    "/@" <> encode_segment(nickname)
  end

  def profile_path(%User{nickname: nickname, domain: domain, local: false})
      when is_binary(nickname) and nickname != "" and is_binary(domain) and domain != "" do
    "/@" <> encode_segment(nickname) <> "@" <> encode_segment(domain)
  end

  def profile_path(%{handle: handle}) when is_binary(handle) and handle != "" do
    profile_path(handle)
  end

  def profile_path(%{nickname: nickname}) when is_binary(nickname) and nickname != "" do
    "/@" <> encode_segment(nickname)
  end

  def profile_path(handle) when is_binary(handle) do
    handle = String.trim(handle)

    cond do
      handle == "" ->
        nil

      String.starts_with?(handle, ["http://", "https://"]) ->
        nil

      true ->
        handle
        |> String.trim_leading("@")
        |> profile_path_from_handle()
    end
  end

  def profile_path(_handle), do: nil

  def followers_path(subject) do
    with path when is_binary(path) <- profile_path(subject) do
      path <> "/followers"
    end
  end

  def following_path(subject) do
    with path when is_binary(path) <- profile_path(subject) do
      path <> "/following"
    end
  end

  defp profile_path_from_handle(handle) when is_binary(handle) do
    case String.split(handle, "@", parts: 2) do
      [nickname, domain] when nickname != "" and domain != "" ->
        "/@" <> encode_segment(nickname) <> "@" <> encode_segment(domain)

      [nickname] when nickname != "" ->
        "/@" <> encode_segment(nickname)

      _ ->
        nil
    end
  end

  defp encode_segment(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> URI.encode(&URI.char_unreserved?/1)
  end
end
