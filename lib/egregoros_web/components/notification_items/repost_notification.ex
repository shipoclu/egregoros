defmodule EgregorosWeb.Components.NotificationItems.RepostNotification do
  @moduledoc """
  Component for rendering a Repost/Announce notification.
  Displayed when someone reposts the current user's post.
  """
  use EgregorosWeb, :html

  attr :id, :string, required: true
  attr :entry, :map, required: true

  def repost_notification(assigns) do
    ~H"""
    <article
      id={@id}
      data-role="notification"
      data-type="Announce"
      data-importance="medium"
      class="relative border border-[color:var(--border-muted)] bg-[color:var(--bg-base)] p-5 transition hover:bg-[color:var(--bg-subtle)]"
    >
      <div class="flex items-start gap-3 pl-2">
        <div data-role="notification-avatar">
          <.avatar
            size="sm"
            name={@entry.actor.display_name}
            src={@entry.actor.avatar_url}
          />
        </div>

        <div class="min-w-0 flex-1 space-y-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="flex flex-wrap items-center gap-2 text-sm font-semibold text-[color:var(--text-primary)]">
                <.icon name="hero-arrow-path" class="size-4 text-[color:var(--text-muted)]" />
                <span data-role="notification-message" class="truncate">
                  {emoji_inline(@entry.message, @entry.message_emojis)}
                </span>
              </p>
              <p class="mt-1 font-mono text-xs text-[color:var(--text-muted)]">
                {@entry.actor.handle}
              </p>
            </div>

            <span class="shrink-0">
              <.time_ago at={@entry.notification.inserted_at} />
            </span>
          </div>

          <div
            :if={@entry.preview_html}
            data-role="notification-preview"
            class="border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] p-4 text-sm text-[color:var(--text-secondary)]"
          >
            {@entry.preview_html}
          </div>

          <div
            :if={is_binary(@entry.target_path) and @entry.target_path != ""}
            class="flex justify-end"
          >
            <.link
              navigate={@entry.target_path}
              data-role="notification-target"
              class="text-[color:var(--text-muted)] hover:text-[color:var(--text-primary)] hover:underline underline-offset-2 inline-flex items-center gap-1 text-xs font-bold uppercase tracking-wide transition focus-visible:outline-none focus-brutal"
              aria-label="Open post"
            >
              Open post <.icon name="hero-arrow-right" class="size-4" />
            </.link>
          </div>
        </div>
      </div>
    </article>
    """
  end
end
