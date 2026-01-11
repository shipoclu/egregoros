defmodule EgregorosWeb.SettingsHTML do
  use EgregorosWeb, :html

  alias EgregorosWeb.URL

  embed_templates "settings_html/*"

  defp user_avatar_src(user) when is_map(user) do
    user
    |> Map.get(:avatar_url)
    |> URL.absolute()
  end

  defp user_avatar_src(_user), do: nil

  defp user_banner_src(user) when is_map(user) do
    user
    |> Map.get(:banner_url)
    |> URL.absolute()
  end

  defp user_banner_src(_user), do: nil

  defp user_display_name(user) when is_map(user) do
    Map.get(user, :name) || Map.get(user, :nickname) || "Unknown"
  end

  defp user_display_name(_user), do: "Unknown"

  defp user_nickname(user) when is_map(user) do
    Map.get(user, :nickname) || "unknown"
  end

  defp user_nickname(_user), do: "unknown"
end
