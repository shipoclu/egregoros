defmodule EgregorosWeb.URL do
  alias EgregorosWeb.Endpoint

  def absolute(nil), do: nil
  def absolute(""), do: ""

  def absolute(url) when is_binary(url) do
    absolute(url, Endpoint.url())
  end

  def absolute(nil, _base), do: nil
  def absolute("", _base), do: ""

  def absolute(url, base) when is_binary(url) do
    url = String.trim(url)

    cond do
      url == "" ->
        ""

      String.starts_with?(url, ["http://", "https://"]) ->
        url

      base_url?(base) ->
        base = maybe_uploads_base(url, base)
        path = if String.starts_with?(url, "/"), do: url, else: "/" <> url

        base
        |> URI.merge(path)
        |> URI.to_string()

      true ->
        absolute(url)
    end
  end

  def absolute(url, _base), do: absolute(url)

  defp base_url?(base) when is_binary(base) do
    case URI.parse(base) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp base_url?(_base), do: false

  defp maybe_uploads_base(url, base) when is_binary(url) and is_binary(base) do
    if uploads_path?(url) do
      case uploads_base_url() do
        uploads_base when is_binary(uploads_base) and uploads_base != "" ->
          if same_host?(base, Endpoint.url()), do: uploads_base, else: base

        _ ->
          base
      end
    else
      base
    end
  end

  defp maybe_uploads_base(_url, base), do: base

  defp uploads_path?(url) when is_binary(url) do
    url = String.trim(url)

    url == "/uploads" or String.starts_with?(url, "/uploads/") or url == "uploads" or
      String.starts_with?(url, "uploads/")
  end

  defp uploads_path?(_url), do: false

  defp uploads_base_url do
    case Application.get_env(:egregoros, :uploads_base_url) do
      base when is_binary(base) -> String.trim(base)
      _ -> nil
    end
  end

  defp same_host?(url, other) when is_binary(url) and is_binary(other) do
    with %URI{host: host} when is_binary(host) and host != "" <- URI.parse(url),
         %URI{host: other_host} when is_binary(other_host) and other_host != "" <- URI.parse(other) do
      String.downcase(host) == String.downcase(other_host)
    else
      _ -> false
    end
  end

  defp same_host?(_url, _other), do: false

  def local_object_uuid(ap_id) when is_binary(ap_id) do
    base = Endpoint.url() <> "/objects/"

    if String.starts_with?(ap_id, base) do
      uuid = String.replace_prefix(ap_id, base, "")
      if uuid == "", do: nil, else: uuid
    else
      nil
    end
  end

  def local_object_uuid(_ap_id), do: nil
end
