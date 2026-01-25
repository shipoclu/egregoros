defmodule EgregorosWeb.MastodonAPI.MediaURLs do
  @moduledoc false

  alias Egregoros.Object
  alias EgregorosWeb.SafeMediaURL

  def preview_url(subject, fallback \\ nil)

  def preview_url(%Object{data: %{} = data}, fallback), do: preview_url(data, fallback)

  def preview_url(%{} = subject, %Object{data: %{} = data}), do: preview_url(subject, data)

  def preview_url(%{} = subject, %{} = fallback) do
    preview_url_from(subject) || preview_url_from(fallback)
  end

  def preview_url(%{} = subject, _fallback), do: preview_url_from(subject)

  def preview_url(_subject, _fallback), do: nil

  defp preview_url_from(%{"icon" => %{"url" => [%{"href" => href} | _]}}) when is_binary(href) do
    SafeMediaURL.safe(href)
  end

  defp preview_url_from(%{"icon" => %{"url" => [%{"url" => href} | _]}}) when is_binary(href) do
    SafeMediaURL.safe(href)
  end

  defp preview_url_from(%{"icon" => %{"url" => href}}) when is_binary(href) do
    SafeMediaURL.safe(href)
  end

  defp preview_url_from(_subject), do: nil
end
