defmodule EgregorosWeb.PrivacyLive do
  use EgregorosWeb, :live_view

  alias Egregoros.Notifications
  alias Egregoros.MiniApps.ContextConsents
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.WalletConnections
  alias Egregoros.Relationship
  alias Egregoros.Relationships
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.URL
  alias EgregorosWeb.ViewModels.Actor, as: ActorVM

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case Map.get(session, "user_id") do
        nil -> nil
        id -> Users.get(id)
      end

    mutes = list_relationships("Mute", current_user)
    blocks = list_relationships("Block", current_user)

    wallet_connections =
      case current_user do
        %User{id: user_id} -> WalletConnections.list_for_user(user_id)
        _ -> []
      end

    context_consents =
      case current_user do
        %User{id: user_id} -> ContextConsents.list_for_user(user_id)
        _ -> []
      end

    notification_consents =
      case current_user do
        %User{id: user_id} -> NotificationConsents.list_for_user(user_id)
        _ -> []
      end

    oauth_grants =
      case current_user do
        %User{id: user_id} -> OAuthRegistrations.list_user_grants(user_id)
        _ -> []
      end

    {:ok,
     socket
     |> assign(
       current_user: current_user,
       notifications_count: notifications_count(current_user),
       mutes: mutes,
       blocks: blocks,
       targets_by_ap_id: target_cards(mutes ++ blocks)
     )
     |> stream(:context_consents, context_consents, dom_id: &"context-consent-#{&1.id}")
     |> stream(:notification_consents, notification_consents,
       dom_id: &"notification-consent-#{&1.id}"
     )
     |> stream(:oauth_grants, oauth_grants, dom_id: &"oauth-grant-#{&1.id}")
     |> stream(:wallet_connections, wallet_connections, dom_id: &"wallet-connection-#{&1.id}")}
  end

  @impl true
  def handle_event("privacy-unmute", %{"id" => id}, socket) do
    {:noreply, delete_relationship(socket, id, "Mute", :mutes)}
  end

  def handle_event("privacy-unblock", %{"id" => id}, socket) do
    {:noreply, delete_relationship(socket, id, "Block", :blocks)}
  end

  def handle_event("privacy-disconnect-wallet", %{"origin" => origin}, socket) do
    case socket.assigns.current_user do
      %User{id: user_id} ->
        :ok = WalletConnections.revoke(user_id, origin)

        {:noreply,
         stream(socket, :wallet_connections, WalletConnections.list_for_user(user_id),
           reset: true,
           dom_id: &"wallet-connection-#{&1.id}"
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("privacy-revoke-context", %{"origin" => origin}, socket) do
    case socket.assigns.current_user do
      %User{id: user_id} ->
        :ok = ContextConsents.revoke(user_id, origin)

        {:noreply,
         stream(socket, :context_consents, ContextConsents.list_for_user(user_id),
           reset: true,
           dom_id: &"context-consent-#{&1.id}"
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("privacy-revoke-notifications", %{"origin" => origin}, socket) do
    case socket.assigns.current_user do
      %User{id: user_id} ->
        :ok = NotificationConsents.revoke(user_id, origin)

        {:noreply,
         stream(
           socket,
           :notification_consents,
           NotificationConsents.list_for_user(user_id),
           reset: true,
           dom_id: &"notification-consent-#{&1.id}"
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("privacy-revoke-oauth", %{"origin" => origin}, socket) do
    case socket.assigns.current_user do
      %User{id: user_id} ->
        :ok = OAuthRegistrations.revoke_user_grant(origin, user_id)

        {:noreply,
         stream(socket, :oauth_grants, OAuthRegistrations.list_user_grants(user_id),
           reset: true,
           dom_id: &"oauth-grant-#{&1.id}"
         )}

      _ ->
        {:noreply, socket}
    end
  end

  defp delete_relationship(socket, id, type, key) do
    relationship_id = id |> to_string() |> String.trim()

    with %User{} = current_user <- socket.assigns.current_user,
         true <- flake_id?(relationship_id),
         %Relationship{} = relationship <- Relationships.get(relationship_id),
         true <- relationship.type == type,
         true <- relationship.actor == current_user.ap_id,
         {:ok, _relationship} <- Repo.delete(relationship) do
      socket
      |> assign(
        key,
        Enum.reject(Map.get(socket.assigns, key, []), &(&1.id == relationship_id))
      )
      |> refresh_targets()
    else
      _ -> socket
    end
  end

  defp flake_id?(id) when is_binary(id) do
    id = String.trim(id)
    byte_size(id) == 18 and FlakeId.flake_id?(id)
  end

  defp flake_id?(_id), do: false

  defp refresh_targets(socket) do
    mutes = Map.get(socket.assigns, :mutes, [])
    blocks = Map.get(socket.assigns, :blocks, [])
    assign(socket, :targets_by_ap_id, target_cards(mutes ++ blocks))
  end

  defp target_cards(relationships) when is_list(relationships) do
    ap_ids =
      relationships
      |> Enum.map(& &1.object)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    ap_ids
    |> Users.list_by_ap_ids()
    |> Map.new(fn user ->
      {user.ap_id,
       %{
         display_name: user.name || user.nickname || user.ap_id,
         handle: ActorVM.handle(user, user.ap_id),
         avatar_url: URL.absolute(user.avatar_url, user.ap_id),
         emojis: Map.get(user, :emojis, [])
       }}
    end)
  end

  defp target_cards(_relationships), do: %{}

  defp list_relationships(_type, nil), do: []

  defp list_relationships(type, %User{} = user) when is_binary(type) do
    Relationships.list_by_type_actor(type, user.ap_id, limit: 80)
  end

  defp notifications_count(nil), do: 0

  defp notifications_count(%User{} = user) do
    user
    |> Notifications.list_for_user(limit: 20, include_offers?: true)
    |> length()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} mini_app_host={@mini_app_host}>
      <AppShell.app_shell
        id="privacy-shell"
        nav_id="privacy-nav"
        main_id="privacy-main"
        active={:settings}
        current_user={@current_user}
        notifications_count={@notifications_count}
      >
        <section class="space-y-6">
          <.card class="p-6">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
                  Settings
                </p>
                <h2 class="mt-2 text-2xl font-bold text-[color:var(--text-primary)]">
                  Privacy
                </h2>
              </div>
              <.button navigate={~p"/settings"} variant="secondary" size="sm">
                <.icon name="hero-chevron-left" class="size-4" /> Back
              </.button>
            </div>
          </.card>

          <%= if @current_user do %>
            <div class="grid gap-6 lg:grid-cols-2">
              <.card class="p-6">
                <div class="flex items-center justify-between gap-4">
                  <h3 class="text-xl font-bold text-[color:var(--text-primary)]">
                    Muted accounts
                  </h3>
                  <span class="font-mono text-sm text-[color:var(--text-muted)]">
                    {length(@mutes)}
                  </span>
                </div>

                <div class="mt-4 space-y-3">
                  <p :if={@mutes == []} class="text-sm text-[color:var(--text-secondary)]">
                    No muted accounts yet.
                  </p>

                  <div
                    :for={mute <- @mutes}
                    id={"mute-#{mute.id}"}
                    class="flex items-center justify-between gap-4 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-4 py-3 text-sm"
                  >
                    <% target = Map.get(@targets_by_ap_id, mute.object) %>
                    <div class="flex min-w-0 items-center gap-3">
                      <.avatar
                        size="xs"
                        name={Map.get(target || %{}, :display_name, mute.object)}
                        src={Map.get(target || %{}, :avatar_url)}
                      />
                      <div class="min-w-0">
                        <p class="truncate font-bold text-[color:var(--text-primary)]">
                          {emoji_inline(
                            Map.get(target || %{}, :display_name, mute.object),
                            Map.get(target || %{}, :emojis, [])
                          )}
                        </p>
                        <p
                          data-role="privacy-target-handle"
                          class="truncate font-mono text-xs text-[color:var(--text-muted)]"
                        >
                          {Map.get(target || %{}, :handle, mute.object)}
                        </p>
                      </div>
                    </div>
                    <button
                      type="button"
                      data-role="privacy-unmute"
                      phx-click="privacy-unmute"
                      phx-value-id={mute.id}
                      class="border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-xs font-bold uppercase tracking-wide text-[color:var(--text-secondary)] transition hover:bg-[color:var(--text-primary)] hover:text-[color:var(--bg-base)]"
                    >
                      Unmute
                    </button>
                  </div>
                </div>
              </.card>

              <.card class="p-6">
                <div class="flex items-center justify-between gap-4">
                  <h3 class="text-xl font-bold text-[color:var(--text-primary)]">
                    Blocked accounts
                  </h3>
                  <span class="font-mono text-sm text-[color:var(--text-muted)]">
                    {length(@blocks)}
                  </span>
                </div>

                <div class="mt-4 space-y-3">
                  <p :if={@blocks == []} class="text-sm text-[color:var(--text-secondary)]">
                    No blocked accounts yet.
                  </p>

                  <div
                    :for={block <- @blocks}
                    id={"block-#{block.id}"}
                    class="flex items-center justify-between gap-4 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-4 py-3 text-sm"
                  >
                    <% target = Map.get(@targets_by_ap_id, block.object) %>
                    <div class="flex min-w-0 items-center gap-3">
                      <.avatar
                        size="xs"
                        name={Map.get(target || %{}, :display_name, block.object)}
                        src={Map.get(target || %{}, :avatar_url)}
                      />
                      <div class="min-w-0">
                        <p class="truncate font-bold text-[color:var(--text-primary)]">
                          {emoji_inline(
                            Map.get(target || %{}, :display_name, block.object),
                            Map.get(target || %{}, :emojis, [])
                          )}
                        </p>
                        <p
                          data-role="privacy-target-handle"
                          class="truncate font-mono text-xs text-[color:var(--text-muted)]"
                        >
                          {Map.get(target || %{}, :handle, block.object)}
                        </p>
                      </div>
                    </div>
                    <button
                      type="button"
                      data-role="privacy-unblock"
                      phx-click="privacy-unblock"
                      phx-value-id={block.id}
                      class="border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-xs font-bold uppercase tracking-wide text-[color:var(--text-secondary)] transition hover:bg-[color:var(--text-primary)] hover:text-[color:var(--bg-base)]"
                    >
                      Unblock
                    </button>
                  </div>
                </div>
              </.card>
            </div>

            <.card class="p-6">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <h3 class="text-xl font-bold text-[color:var(--text-primary)]">
                    Transactional mini-app messages
                  </h3>
                  <p class="mt-1 text-sm text-[color:var(--text-secondary)]">
                    Manage which app actors may send private ActivityPub notes that mention you.
                  </p>
                </div>
                <.icon name="hero-bell" class="size-6 text-[color:var(--accent)]" />
              </div>

              <div id="notification-consents" phx-update="stream" class="mt-4 space-y-3">
                <p
                  id="notification-consents-empty"
                  class="hidden only:block text-sm text-[color:var(--text-secondary)]"
                >
                  No mini apps have a transactional-message decision.
                </p>
                <div
                  :for={{id, consent} <- @streams.notification_consents}
                  id={id}
                  class="flex flex-col gap-3 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div class="min-w-0">
                    <p class="truncate font-mono text-sm font-bold text-[color:var(--text-primary)]">
                      {consent.app_origin}
                    </p>
                    <p class="mt-1 break-all font-mono text-xs text-[color:var(--text-muted)]">
                      {consent.app_actor_url}
                    </p>
                    <p class="mt-1 text-xs font-bold uppercase tracking-wide text-[color:var(--text-secondary)]">
                      Decision: {consent.decision}
                    </p>
                  </div>
                  <button
                    type="button"
                    data-role="privacy-revoke-notifications"
                    phx-click="privacy-revoke-notifications"
                    phx-value-origin={consent.app_origin}
                    class="shrink-0 border-2 border-[color:var(--border-default)] px-3 py-2 text-xs font-bold uppercase tracking-wide text-[color:var(--text-secondary)] transition hover:border-[color:var(--danger)] hover:text-[color:var(--danger)]"
                  >
                    Reset
                  </button>
                </div>
              </div>
            </.card>

            <.card class="p-6">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <h3 class="text-xl font-bold text-[color:var(--text-primary)]">
                    Mini-app launch context
                  </h3>
                  <p class="mt-1 text-sm text-[color:var(--text-secondary)]">
                    Revoke access to the public note details you previously disclosed.
                  </p>
                </div>
                <.icon name="hero-document-text" class="size-6 text-[color:var(--accent)]" />
              </div>

              <div id="context-consents" phx-update="stream" class="mt-4 space-y-3">
                <p
                  id="context-consents-empty"
                  class="hidden only:block text-sm text-[color:var(--text-secondary)]"
                >
                  No mini apps have launch-context access.
                </p>
                <div
                  :for={{id, consent} <- @streams.context_consents}
                  id={id}
                  class="flex items-center justify-between gap-4 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-4 py-3"
                >
                  <p class="min-w-0 truncate font-mono text-sm font-bold text-[color:var(--text-primary)]">
                    {consent.app_origin}
                  </p>
                  <button
                    type="button"
                    data-role="privacy-revoke-context"
                    phx-click="privacy-revoke-context"
                    phx-value-origin={consent.app_origin}
                    class="shrink-0 border-2 border-[color:var(--border-default)] px-3 py-2 text-xs font-bold uppercase tracking-wide text-[color:var(--text-secondary)] transition hover:border-[color:var(--danger)] hover:text-[color:var(--danger)]"
                  >
                    Revoke
                  </button>
                </div>
              </div>
            </.card>

            <.card class="p-6">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <h3 class="text-xl font-bold text-[color:var(--text-primary)]">
                    Mini-app OAuth access
                  </h3>
                  <p class="mt-1 text-sm text-[color:var(--text-secondary)]">
                    Revoking access invalidates the app's active access and refresh tokens.
                  </p>
                </div>
                <.icon name="hero-key" class="size-6 text-[color:var(--accent)]" />
              </div>

              <div id="oauth-grants" phx-update="stream" class="mt-4 space-y-3">
                <p
                  id="oauth-grants-empty"
                  class="hidden only:block text-sm text-[color:var(--text-secondary)]"
                >
                  No mini apps have OAuth access.
                </p>
                <div
                  :for={{id, grant} <- @streams.oauth_grants}
                  id={id}
                  class="flex flex-col gap-3 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div class="min-w-0">
                    <p class="truncate font-mono text-sm font-bold text-[color:var(--text-primary)]">
                      {grant.app_origin}
                    </p>
                    <div class="mt-2 space-y-1">
                      <p
                        :for={scope <- grant.scopes}
                        id={"#{id}-scope-#{scope}"}
                        data-role="mini-app-oauth-scope"
                        class="text-xs text-[color:var(--text-muted)]"
                      >
                        <span class="font-bold text-[color:var(--text-secondary)]">{scope}</span>
                        <%= if grant.scope_expirations[scope] do %>
                          — authorized until
                          <time datetime={DateTime.to_iso8601(grant.scope_expirations[scope])}>
                            {Calendar.strftime(
                              grant.scope_expirations[scope],
                              "%Y-%m-%d %H:%M UTC"
                            )}
                          </time>
                        <% end %>
                      </p>
                    </div>
                  </div>
                  <button
                    type="button"
                    data-role="privacy-revoke-oauth"
                    phx-click="privacy-revoke-oauth"
                    phx-value-origin={grant.app_origin}
                    class="shrink-0 border-2 border-[color:var(--border-default)] px-3 py-2 text-xs font-bold uppercase tracking-wide text-[color:var(--text-secondary)] transition hover:border-[color:var(--danger)] hover:text-[color:var(--danger)]"
                  >
                    Revoke
                  </button>
                </div>
              </div>
            </.card>

            <.card class="p-6">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <h3 class="text-xl font-bold text-[color:var(--text-primary)]">
                    Mini-app wallet connections
                  </h3>
                  <p class="mt-1 text-sm text-[color:var(--text-secondary)]">
                    Disconnecting an account does not revoke the app’s OAuth access.
                  </p>
                </div>
                <.icon name="hero-wallet" class="size-6 text-[color:var(--accent)]" />
              </div>

              <div id="wallet-connections" phx-update="stream" class="mt-4 space-y-3">
                <p
                  id="wallet-connections-empty"
                  class="hidden only:block text-sm text-[color:var(--text-secondary)]"
                >
                  No mini apps are connected to a wallet.
                </p>

                <div
                  :for={{id, connection} <- @streams.wallet_connections}
                  id={id}
                  class="flex flex-col gap-3 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div class="min-w-0">
                    <p class="truncate font-mono text-sm font-bold text-[color:var(--text-primary)]">
                      {connection.app_origin}
                    </p>
                    <p
                      :for={account <- connection.accounts}
                      data-role="wallet-account"
                      class="mt-1 truncate font-mono text-xs text-[color:var(--text-muted)]"
                    >
                      {account}
                    </p>
                  </div>
                  <button
                    type="button"
                    data-role="privacy-disconnect-wallet"
                    phx-click="privacy-disconnect-wallet"
                    phx-value-origin={connection.app_origin}
                    class="shrink-0 border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-xs font-bold uppercase tracking-wide text-[color:var(--text-secondary)] transition hover:border-[color:var(--danger)] hover:text-[color:var(--danger)]"
                  >
                    Disconnect
                  </button>
                </div>
              </div>
            </.card>
          <% else %>
            <.card class="p-6">
              <p data-role="privacy-auth-required" class="text-sm text-[color:var(--text-secondary)]">
                Sign in to manage blocks and mutes.
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
end
