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
end
