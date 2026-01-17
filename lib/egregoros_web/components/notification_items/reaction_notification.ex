defmodule EgregorosWeb.Components.NotificationItems.ReactionNotification do
  @moduledoc """
  Component for rendering an EmojiReact notification.
  Displayed when someone reacts to the current user's post with an emoji.
  Uses compact inline layout due to low importance.
  """
  use EgregorosWeb, :html

  attr :id, :string, required: true
  attr :entry, :map, required: true

  def reaction_notification(assigns) do
    ~H"""
    <article
      id={@id}
      data-role="notification"
      data-type="EmojiReact"
      data-importance="low"
      class="relative bg-[color:var(--bg-base)] p-0"
    >
      <div class="flex items-center gap-2.5 pl-2">
        <.avatar
          size="xs"
          name={@entry.actor.display_name}
          src={@entry.actor.avatar_url}
          class="shrink-0 !h-6 !w-6 !border"
        />
        <%= case @entry.reaction_emoji do %>
          <% %{type: :unicode, emoji: emoji} -> %>
            <span class="shrink-0 text-base">{emoji}</span>
          <% %{type: :custom, url: url, shortcode: shortcode} -> %>
            <img
              src={url}
              alt={shortcode}
              class="size-4 shrink-0 object-contain"
              loading="lazy"
            />
          <% _ -> %>
            <.icon name="hero-face-smile" class="size-3.5 shrink-0 text-[color:var(--text-muted)]" />
        <% end %>
        <span class="min-w-0 flex-1 truncate text-sm text-[color:var(--text-secondary)]">
          <%= if is_binary(@entry.target_path) and @entry.target_path != "" do %>
            <.link
              navigate={@entry.target_path}
              data-role="notification-target"
              class="block truncate hover:underline underline-offset-2"
              aria-label="Open post"
            >
              {emoji_inline(@entry.message, @entry.message_emojis)}
            </.link>
          <% else %>
            {emoji_inline(@entry.message, @entry.message_emojis)}
          <% end %>
        </span>
        <span class="shrink-0 text-xs text-[color:var(--text-muted)]">
          <.time_ago at={@entry.notification.inserted_at} />
        </span>
      </div>
    </article>
    """
  end
end
