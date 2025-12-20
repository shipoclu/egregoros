defmodule PleromaReduxWeb.URL do
  alias PleromaReduxWeb.Endpoint

  def absolute(nil), do: nil
  def absolute(""), do: ""

  def absolute(url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      url
    else
      base = Endpoint.url()
      path = if String.starts_with?(url, "/"), do: url, else: "/" <> url
      base <> path
    end
  end

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
