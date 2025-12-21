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
        profile_path_from_url(handle)

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

  defp profile_path_from_url(url) when is_binary(url) do
    with %URI{host: host} = uri <- URI.parse(url),
         true <- is_binary(host) and host != "",
         domain <- domain_from_uri(uri),
         nickname <- nickname_from_uri(uri),
         true <- nickname != "" do
      "/@" <> encode_segment(nickname) <> "@" <> encode_segment(domain)
    else
      _ -> nil
    end
  end

  defp domain_from_uri(%URI{host: host, port: port}) when is_binary(host) do
    cond do
      is_integer(port) and port > 0 and port not in [80, 443] ->
        host <> ":" <> Integer.to_string(port)

      true ->
        host
    end
  end

  defp domain_from_uri(_uri), do: ""

  defp nickname_from_uri(%URI{path: path}) do
    path
    |> to_string()
    |> String.trim("/")
    |> path_basename()
    |> String.trim_leading("@")
  end

  defp nickname_from_uri(_uri), do: ""

  defp path_basename(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [] -> ""
      segments -> List.last(segments)
    end
  end

  defp encode_segment(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> URI.encode(&URI.char_unreserved?/1)
  end
end
