defmodule EgregorosWeb.OAuthHTML do
  use EgregorosWeb, :html

  embed_templates "oauth_html/*"

  def oauth_permission("identify") do
    %{
      title: "Link your Fediverse identity",
      description:
        "Share your account ID, handle, display name, and profile URL. This does not permit reading timelines or posts.",
      risk: :base
    }
  end

  def oauth_permission("read") do
    %{
      title: "Read authenticated account data",
      description:
        "Read data available to your signed-in account, including timelines, notifications, conversations, and private visibility where an API permits it.",
      risk: :sensitive
    }
  end

  def oauth_permission("write") do
    %{
      title: "Change account data",
      description:
        "Use write APIs that may create, edit, and delete posts or change other account state.",
      risk: :danger
    }
  end

  def oauth_permission("follow") do
    %{
      title: "Manage follows",
      description: "Follow or unfollow accounts and answer follow requests as you.",
      risk: :sensitive
    }
  end

  def oauth_permission("push") do
    %{
      title: "Manage push subscriptions",
      description: "Create or change API push-notification subscriptions for this account.",
      risk: :sensitive
    }
  end

  def oauth_permission(scope) do
    %{
      title: "Additional permission: #{scope}",
      description: "Use the named OAuth permission shown above.",
      risk: :sensitive
    }
  end

  def format_authorization_lifetime(seconds) when rem(seconds, 31_536_000) == 0,
    do: duration(div(seconds, 31_536_000), "year")

  def format_authorization_lifetime(seconds) when rem(seconds, 2_592_000) == 0,
    do: duration(div(seconds, 2_592_000), "month")

  def format_authorization_lifetime(seconds) when rem(seconds, 86_400) == 0,
    do: duration(div(seconds, 86_400), "day")

  def format_authorization_lifetime(seconds) when rem(seconds, 3_600) == 0,
    do: duration(div(seconds, 3_600), "hour")

  def format_authorization_lifetime(seconds) when rem(seconds, 60) == 0,
    do: duration(div(seconds, 60), "minute")

  def format_authorization_lifetime(seconds), do: duration(seconds, "second")

  defp duration(1, unit), do: "1 #{unit}"
  defp duration(count, unit), do: "#{count} #{unit}s"
end
