defmodule EgregorosWeb.Components.NotificationItems.FollowRequestNotification do
  @moduledoc """
  Component for rendering a follow request notification.
  Displayed when someone requests to follow a user with a locked account.
  Includes accept/reject action buttons.
  """
  use EgregorosWeb, :html

  attr :id, :string, required: true
  attr :entry, :map, required: true

  def follow_request_notification(assigns) do
    ~H"""
    <article
      id={@id}
      data-role="follow-request"
      class="border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-6 transition hover:bg-[color:var(--bg-subtle)]"
    >
      <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div class="flex items-start gap-4">
          <.avatar size="sm" name={@entry.actor.display_name} src={@entry.actor.avatar_url} />

          <div class="min-w-0">
            <p class="text-sm font-bold text-[color:var(--text-primary)]">
              {@entry.actor.display_name}
            </p>
            <p class="mt-1 font-mono text-xs text-[color:var(--text-muted)]">
              {@entry.actor.handle}
            </p>
          </div>
        </div>

        <div class="flex flex-wrap items-center justify-end gap-2">
          <.button
            type="button"
            size="sm"
            data-role="follow-request-accept"
            phx-click="follow_request_accept"
            phx-value-id={@entry.relationship.id}
            phx-disable-with="Accepting..."
          >
            Accept
          </.button>

          <.button
            type="button"
            size="sm"
            variant="secondary"
            data-role="follow-request-reject"
            phx-click="follow_request_reject"
            phx-value-id={@entry.relationship.id}
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
