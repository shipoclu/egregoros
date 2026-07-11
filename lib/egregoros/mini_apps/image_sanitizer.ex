defmodule Egregoros.MiniApps.ImageSanitizer do
  @moduledoc false

  alias Egregoros.Config
  alias Egregoros.MiniApps.ImageProxy

  @type sanitized :: %{body: binary(), content_type: binary()}

  @callback sanitize(binary(), binary()) :: {:ok, sanitized()} | {:error, atom()}

  def sanitize(body, content_type) when is_binary(body) and is_binary(content_type) do
    __MODULE__
    |> Config.get(ImageProxy)
    |> apply(:sanitize, [body, content_type])
  end

  def sanitize(_body, _content_type), do: {:error, :invalid_image}
end
