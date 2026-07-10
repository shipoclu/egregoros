defmodule Egregoros.MiniApps.ResolvedCard do
  @moduledoc false

  @enforce_keys [
    :source_url,
    :app_origin,
    :app_name,
    :title,
    :button_title,
    :launch_url,
    :manifest
  ]
  defstruct [
    :source_url,
    :app_origin,
    :app_name,
    :title,
    :button_title,
    :launch_url,
    :image_url,
    :manifest
  ]
end
