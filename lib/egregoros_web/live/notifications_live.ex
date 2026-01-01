defmodule EgregorosWeb.NotificationsLive do
  use EgregorosWeb, :live_view

  alias Egregoros.Activities.Accept
  alias Egregoros.Activities.Reject
  alias Egregoros.CustomEmojis
  alias Egregoros.HTML
  alias Egregoros.Notifications
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Relationships
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.ViewModels.Actor, as: ActorVM

  @page_size 20

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case Map.get(session, "user_id") do
        nil -> nil
        id -> Users.get(id)
      end

    if connected?(socket) and match?(%User{}, current_user) do
      Notifications.subscribe(current_user.ap_id)
    end

    notifications = list_notifications(current_user, limit: @page_size)
    follow_requests = list_follow_requests(current_user, limit: @page_size)

    {:ok,
     socket
     |> assign(
       current_user: current_user,
       notifications_count: notifications_count(current_user),
       notifications_filter: "all",
       notifications_cursor: notifications_cursor(notifications),
       notifications_end?: length(notifications) < @page_size,
       follow_requests: decorate_follow_requests(follow_requests)
     )
     |> stream(:notifications, decorate_notifications(notifications),
       dom_id: &notification_dom_id/1
     )}
  end

  @impl true
  def handle_info({:notification_created, activity}, socket) do
    case socket.assigns.current_user do
      %User{} ->
        entry = decorate_notification(activity)

        {:noreply,
         socket
         |> stream_insert(:notifications, entry, at: 0)
         |> assign(:notifications_count, socket.assigns.notifications_count + 1)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    cursor = socket.assigns.notifications_cursor

    cond do
      socket.assigns.notifications_end? ->
        {:noreply, socket}

      is_nil(cursor) ->
        {:noreply, assign(socket, notifications_end?: true)}

      true ->
        notifications =
          list_notifications(socket.assigns.current_user,
            limit: @page_size,
            max_id: cursor
          )

        socket =
          if notifications == [] do
            assign(socket, notifications_end?: true)
          else
            new_cursor = notifications_cursor(notifications)
            notifications_end? = length(notifications) < @page_size

            socket =
              Enum.reduce(decorate_notifications(notifications), socket, fn entry, socket ->
                stream_insert(socket, :notifications, entry, at: -1)
              end)

            assign(socket,
              notifications_cursor: new_cursor,
              notifications_end?: notifications_end?
            )
          end

        {:noreply, socket}
    end
  end

  def handle_event("set_notifications_filter", %{"filter" => filter}, socket) do
    filter = filter |> to_string() |> String.trim()

    if filter in ~w(all follows requests likes reposts mentions reactions) do
      {:noreply, assign(socket, notifications_filter: filter)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("follow_request_accept", %{"id" => id}, socket) do
    with %User{} = current_user <- socket.assigns.current_user,
         {relationship_id, ""} <- Integer.parse(to_string(id)),
         %{type: "FollowRequest", object: object_ap_id, activity_ap_id: follow_ap_id} <-
           Relationships.get(relationship_id),
         true <- object_ap_id == current_user.ap_id,
         follow_ap_id when is_binary(follow_ap_id) and follow_ap_id != "" <- follow_ap_id,
         %Object{type: "Follow"} = follow_object <- Objects.get_by_ap_id(follow_ap_id),
         {:ok, _accept_object} <-
           Pipeline.ingest(Accept.build(current_user, follow_object), local: true) do
      {:noreply,
       socket
       |> put_flash(:info, "Follow request accepted.")
       |> assign(
         follow_requests:
           decorate_follow_requests(list_follow_requests(current_user, limit: @page_size))
       )}
    else
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("follow_request_reject", %{"id" => id}, socket) do
    with %User{} = current_user <- socket.assigns.current_user,
         {relationship_id, ""} <- Integer.parse(to_string(id)),
         %{type: "FollowRequest", object: object_ap_id, activity_ap_id: follow_ap_id} <-
           Relationships.get(relationship_id),
         true <- object_ap_id == current_user.ap_id,
         follow_ap_id when is_binary(follow_ap_id) and follow_ap_id != "" <- follow_ap_id,
         %Object{type: "Follow"} = follow_object <- Objects.get_by_ap_id(follow_ap_id),
         {:ok, _reject_object} <-
           Pipeline.ingest(Reject.build(current_user, follow_object), local: true) do
      {:noreply,
       socket
       |> put_flash(:info, "Follow request rejected.")
       |> assign(
         follow_requests:
           decorate_follow_requests(list_follow_requests(current_user, limit: @page_size))
       )}
    else
      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <AppShell.app_shell
        id="notifications-shell"
        nav_id="notifications-nav"
        main_id="notifications-main"
        active={:notifications}
        current_user={@current_user}
        notifications_count={@notifications_count}
      >
        <section class="space-y-4">
          <.card class="p-6">
            <div class="flex items-center justify-between gap-4">
              <div>
                <p class="text-xs uppercase tracking-[0.3em] text-slate-500 dark:text-slate-400">
                  Notifications
                </p>
                <h2 class="mt-2 font-display text-2xl text-slate-900 dark:text-slate-100">
                  Activity
                </h2>
              </div>
            </div>

            <div :if={@current_user} class="mt-4 flex flex-wrap items-center gap-2">
              <.filter_button
                filter="all"
                current={@notifications_filter}
                label="All"
                icon="hero-squares-2x2"
              />
              <.filter_button
                filter="follows"
                current={@notifications_filter}
                label="Follows"
                icon="hero-user-plus"
              />
              <.filter_button
                filter="requests"
                current={@notifications_filter}
                label="Requests"
                icon="hero-user-circle"
              />
              <.filter_button
                filter="likes"
                current={@notifications_filter}
                label="Likes"
                icon="hero-heart"
              />
              <.filter_button
                filter="reposts"
                current={@notifications_filter}
                label="Reposts"
                icon="hero-arrow-path"
              />
              <.filter_button
                filter="mentions"
                current={@notifications_filter}
                label="Mentions"
                icon="hero-at-symbol"
              />
              <.filter_button
                filter="reactions"
                current={@notifications_filter}
                label="Reactions"
                icon="hero-face-smile"
              />
            </div>
          </.card>

          <%= if @current_user do %>
            <div
              id="notifications-list"
              data-role="notifications-list"
              data-filter={@notifications_filter}
              class="space-y-4"
            >
              <div data-role="follow-requests" class="space-y-4">
                <div
                  id="follow-requests-empty"
                  class="hidden only:block rounded-3xl border border-slate-200/80 bg-white/70 p-6 text-sm text-slate-600 shadow-sm shadow-slate-200/20 dark:border-slate-700/70 dark:bg-slate-950/50 dark:text-slate-300 dark:shadow-slate-900/30"
                >
                  No follow requests yet.
                </div>

                <.follow_request_item
                  :for={entry <- @follow_requests}
                  id={"follow-request-#{entry.relationship.id}"}
                  entry={entry}
                />
              </div>

              <div
                id="notifications-stream"
                data-role="notifications-stream"
                phx-update="stream"
                class="space-y-4"
              >
                <div
                  id="notifications-empty"
                  class="hidden only:block rounded-3xl border border-slate-200/80 bg-white/70 p-6 text-sm text-slate-600 shadow-sm shadow-slate-200/20 dark:border-slate-700/70 dark:bg-slate-950/50 dark:text-slate-300 dark:shadow-slate-900/30"
                >
                  No notifications yet.
                </div>

                <.notification_item
                  :for={{id, entry} <- @streams.notifications}
                  id={id}
                  entry={entry}
                />
              </div>
            </div>

            <div :if={!@notifications_end?} class="flex justify-center py-2">
              <.button
                data-role="notifications-load-more"
                phx-click="load_more"
                phx-disable-with="Loading..."
                aria-label="Load more notifications"
                variant="secondary"
              >
                <.icon name="hero-chevron-down" class="size-4" /> Load more
              </.button>
            </div>
          <% else %>
            <.card class="p-6">
              <p
                data-role="notifications-auth-required"
                class="text-sm text-slate-600 dark:text-slate-300"
              >
                Sign in to view notifications.
              </p>
              <div class="mt-4 flex flex-wrap items-center gap-2">
                <.button navigate={~p"/login"} size="sm">Login</.button>
                <.button navigate={~p"/register"} size="sm" variant="secondary">Register</.button>
              </div>
            </.card>
          <% end %>
        </section>
      </AppShell.app_shell>
    </Layouts.app>
    """
  end

  attr :filter, :string, required: true
  attr :current, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp filter_button(assigns) do
    assigns = assign(assigns, active?: assigns.filter == assigns.current)

    ~H"""
    <button
      type="button"
      data-role="notifications-filter"
      data-filter={@filter}
      data-active={if @active?, do: "true", else: "false"}
      phx-click={set_filter_js(@filter)}
      aria-pressed={@active?}
      class={[
        "inline-flex items-center gap-2 rounded-full border px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] transition",
        "data-[active=true]:border-slate-900 data-[active=true]:bg-slate-900 data-[active=true]:text-white data-[active=true]:shadow-lg data-[active=true]:shadow-slate-900/20 data-[active=true]:hover:bg-slate-800 dark:data-[active=true]:border-slate-100 dark:data-[active=true]:bg-slate-100 dark:data-[active=true]:text-slate-900 dark:data-[active=true]:hover:bg-white",
        "data-[active=false]:border-slate-200/80 data-[active=false]:bg-white/70 data-[active=false]:text-slate-700 data-[active=false]:hover:-translate-y-0.5 data-[active=false]:hover:bg-white dark:data-[active=false]:border-slate-700/80 dark:data-[active=false]:bg-slate-950/60 dark:data-[active=false]:text-slate-200 dark:data-[active=false]:hover:bg-slate-950"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp follow_request_item(assigns) do
    ~H"""
    <article
      id={@id}
      data-role="follow-request"
      class="rounded-3xl border border-white/80 bg-white/80 p-6 shadow-lg shadow-slate-200/30 backdrop-blur transition hover:-translate-y-0.5 hover:shadow-xl dark:border-slate-700/60 dark:bg-slate-900/70 dark:shadow-slate-900/50 motion-safe:animate-rise"
    >
      <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div class="flex items-start gap-4">
          <.avatar size="sm" name={@entry.actor.display_name} src={@entry.actor.avatar_url} />

          <div class="min-w-0">
            <p class="text-sm font-semibold text-slate-900 dark:text-slate-100">
              {@entry.actor.display_name}
            </p>
            <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
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

  defp notification_item(assigns) do
    ~H"""
    <article
      id={@id}
      data-role="notification"
      data-type={@entry.type}
      class="rounded-3xl border border-white/80 bg-white/80 p-6 shadow-lg shadow-slate-200/30 backdrop-blur transition hover:-translate-y-0.5 hover:shadow-xl dark:border-slate-700/60 dark:bg-slate-900/70 dark:shadow-slate-900/50 motion-safe:animate-rise"
    >
      <div class="flex items-start gap-4">
        <.avatar size="sm" name={@entry.actor.display_name} src={@entry.actor.avatar_url} />

        <div class="min-w-0 flex-1 space-y-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="flex flex-wrap items-center gap-2 text-sm font-semibold text-slate-900 dark:text-slate-100">
                <.icon name={@entry.icon} class="size-4 text-slate-500 dark:text-slate-400" />
                <span class="truncate">{@entry.message}</span>
              </p>
              <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                {@entry.actor.handle}
              </p>
            </div>

            <span class="shrink-0">
              <.time_ago at={@entry.notification.inserted_at} />
            </span>
          </div>

          <div
            :if={@entry.preview_html}
            class="rounded-2xl border border-slate-200/80 bg-white/70 p-4 text-sm text-slate-700 shadow-sm shadow-slate-200/20 dark:border-slate-700/70 dark:bg-slate-950/50 dark:text-slate-200 dark:shadow-slate-900/30"
          >
            {@entry.preview_html}
          </div>
        </div>
      </div>
    </article>
    """
  end

  defp set_filter_js(filter) when is_binary(filter) do
    JS.set_attribute({"data-filter", filter}, to: "#notifications-list")
    |> JS.set_attribute({"aria-pressed", "false"}, to: "button[data-role='notifications-filter']")
    |> JS.set_attribute({"data-active", "false"}, to: "button[data-role='notifications-filter']")
    |> JS.set_attribute({"aria-pressed", "true"},
      to: "button[data-role='notifications-filter'][data-filter='#{filter}']"
    )
    |> JS.set_attribute({"data-active", "true"},
      to: "button[data-role='notifications-filter'][data-filter='#{filter}']"
    )
    |> JS.push("set_notifications_filter", value: %{filter: filter})
  end

  defp list_notifications(nil, _opts), do: []

  defp list_notifications(%User{} = user, opts) when is_list(opts) do
    Notifications.list_for_user(user, opts)
  end

  defp list_follow_requests(nil, _opts), do: []

  defp list_follow_requests(%User{} = user, opts) when is_list(opts) do
    limit =
      opts
      |> Keyword.get(:limit, @page_size)
      |> max(1)
      |> min(80)

    Relationships.list_by_type_object("FollowRequest", user.ap_id, limit)
  end

  defp decorate_notifications(notifications) when is_list(notifications) do
    Enum.map(notifications, &decorate_notification/1)
  end

  defp decorate_follow_requests(relationships) when is_list(relationships) do
    Enum.map(relationships, fn relationship ->
      %{
        relationship: relationship,
        actor: ActorVM.card(relationship.actor)
      }
    end)
  end

  defp decorate_notification(%{type: type} = notification) when is_binary(type) do
    actor = ActorVM.card(notification.actor)

    {icon, message, preview_html} =
      case type do
        "Follow" ->
          {"hero-user-plus", "#{actor.display_name} followed you", nil}

        "Like" ->
          {"hero-heart", "#{actor.display_name} liked your post",
           note_preview(notification.object)}

        "Announce" ->
          {"hero-arrow-path", "#{actor.display_name} reposted your post",
           note_preview(notification.object)}

        "EmojiReact" ->
          emoji = notification.data |> Map.get("content") |> to_string() |> String.trim()

          message =
            if emoji == "" do
              "#{actor.display_name} reacted to your post"
            else
              "#{actor.display_name} reacted #{emoji} to your post"
            end

          {"hero-face-smile", message, note_preview(notification.object)}

        "Note" ->
          {"hero-at-symbol", "#{actor.display_name} mentioned you",
           note_preview(notification.ap_id)}

        _ ->
          {"hero-bell", "#{actor.display_name} sent activity", nil}
      end

    %{
      notification: notification,
      type: type,
      actor: actor,
      icon: icon,
      message: message,
      preview_html: preview_html
    }
  end

  defp note_preview(note_ap_id) when is_binary(note_ap_id) do
    case Objects.get_by_ap_id(note_ap_id) do
      %{type: "Note"} = object ->
        raw = object.data |> Map.get("content", "") |> to_string()
        emojis = CustomEmojis.from_object(object)
        ap_tags = Map.get(object.data, "tag", [])

        raw
        |> HTML.to_safe_html(format: :html, emojis: emojis, ap_tags: ap_tags)
        |> Phoenix.HTML.raw()

      _ ->
        nil
    end
  end

  defp note_preview(_note_ap_id), do: nil

  defp notifications_count(nil), do: 0

  defp notifications_count(%User{} = user) do
    user
    |> Notifications.list_for_user(limit: @page_size)
    |> length()
  end

  defp notifications_cursor([]), do: nil

  defp notifications_cursor(notifications) when is_list(notifications) do
    case List.last(notifications) do
      %{id: id} when is_integer(id) -> id
      _ -> nil
    end
  end

  defp notification_dom_id(%{notification: %{id: id}}) when is_integer(id),
    do: "notification-#{id}"

  defp notification_dom_id(_notification), do: Ecto.UUID.generate()
end
