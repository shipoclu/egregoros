defmodule EgregorosWeb.Components.NotificationItems.OfferNotification do
  @moduledoc """
  Component for rendering an Offer notification.
  Displayed when a user receives a verifiable credential offer.
  Includes accept/reject action buttons.
  """
  use EgregorosWeb, :html

  attr :id, :string, required: true
  attr :entry, :map, required: true

  def offer_notification(assigns) do
    ~H"""
    <article
      id={@id}
      data-role="notification"
      data-type="Offer"
      data-importance="high"
      class="relative border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-5 transition hover:bg-[color:var(--bg-subtle)]"
    >
      <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div class="flex items-start gap-4">
          <.avatar size="sm" name={@entry.actor.display_name} src={@entry.actor.avatar_url} />

          <div class="min-w-0">
            <p class="flex flex-wrap items-center gap-2 text-sm font-semibold text-[color:var(--text-primary)]">
              <.icon name="hero-gift" class="size-4 text-[color:var(--text-muted)]" />
              <span data-role="notification-message" class="truncate">
                {emoji_inline(@entry.message, @entry.message_emojis)}
              </span>
            </p>
            <p class="mt-1 font-mono text-xs text-[color:var(--text-muted)]">
              {@entry.actor.handle}
            </p>
          </div>
        </div>

        <div class="flex flex-wrap items-center justify-end gap-2">
          <span class="shrink-0 text-xs text-[color:var(--text-muted)]">
            <.time_ago at={@entry.notification.inserted_at} />
          </span>
          <.button
            type="button"
            size="sm"
            data-role="offer-accept"
            phx-click="offer_accept"
            phx-value-id={
              if(@entry.notification.ap_id,
                do: @entry.notification.ap_id,
                else: @entry.notification.id
              )
            }
            phx-disable-with="Accepting..."
          >
            Accept
          </.button>

          <.button
            type="button"
            size="sm"
            variant="secondary"
            data-role="offer-reject"
            phx-click="offer_reject"
            phx-value-id={
              if(@entry.notification.ap_id,
                do: @entry.notification.ap_id,
                else: @entry.notification.id
              )
            }
            phx-disable-with="Rejecting..."
          >
            Reject
          </.button>
        </div>
      </div>
    </article>
    """
  end
end
