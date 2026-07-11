defmodule EgregorosWeb.MiniAppHost do
  @moduledoc false

  use EgregorosWeb, :html

  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.AuthRequest
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.ComposeDraft
  alias Egregoros.MiniApps.ContextConsents
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.ExternalURL
  alias Egregoros.MiniApps.LaunchContext
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.MiniApps.WalletConnections
  alias Egregoros.MiniApps.WalletRequest
  alias Egregoros.Publish
  alias Egregoros.User
  alias Egregoros.Users

  def on_mount(:default, _params, session, socket) do
    user_id = Map.get(session, "user_id")
    if Phoenix.LiveView.connected?(socket), do: Permissions.subscribe(user_id)

    socket =
      socket
      |> Phoenix.Component.assign(:mini_app_host, closed_state())
      |> Phoenix.Component.assign(:mini_app_user_id, user_id)
      |> Phoenix.LiveView.attach_hook(
        :mini_app_host_events,
        :handle_event,
        &handle_host_event/3
      )
      |> Phoenix.LiveView.attach_hook(
        :mini_app_permission_events,
        :handle_info,
        &handle_permission_info/2
      )

    {:cont, socket}
  end

  defp handle_permission_info(
         {:mini_app_permission_revoked, app_origin, kind},
         socket
       )
       when kind in [:context, :notifications, :oauth, :wallet] do
    case socket.assigns.mini_app_host do
      %{card: %Card{app_origin: ^app_origin}} ->
        {:halt, Phoenix.Component.assign(socket, :mini_app_host, closed_state())}

      _state ->
        {:halt, socket}
    end
  end

  defp handle_permission_info(_message, socket), do: {:cont, socket}

  attr :state, :map, required: true

  def host(assigns) do
    ~H"""
    <aside
      id="mini-app-host"
      data-role="mini-app-host"
      data-state={@state.status}
      data-expanded={to_string(@state.expanded?)}
      data-app-origin={card_value(@state, :app_origin)}
      data-launch-id={@state.launch_id}
      data-wallet-enabled={to_string(wallet_value(@state, :wallet_evm_enabled, false))}
      data-wallet-required={to_string(wallet_value(@state, :wallet_evm_required, false))}
      data-wallet-required-chains={
        Jason.encode!(wallet_value(@state, :wallet_evm_required_chains, []))
      }
      data-notifications-enabled={
        to_string(wallet_value(@state, :activity_pub_transactional_mentions, false))
      }
      data-notifications-actor-url={wallet_value(@state, :activity_pub_actor_url, nil)}
      phx-hook="MiniAppHost"
      class={host_classes(@state)}
      aria-hidden={if @state.status == :closed, do: "true", else: "false"}
    >
      <%= if @state.status != :closed and @state.card do %>
        <header class="flex h-14 shrink-0 items-center justify-between gap-3 border-b-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3">
          <div class="flex min-w-0 items-center gap-2">
            <span class="inline-block size-2 shrink-0 bg-[color:var(--success)]"></span>
            <div class="min-w-0">
              <p class="truncate text-sm font-bold text-[color:var(--text-primary)]">
                {@state.card.app_name}
              </p>
              <p class="truncate font-mono text-[10px] text-[color:var(--text-muted)]">
                {display_origin(@state.card.app_origin)}
              </p>
            </div>
          </div>

          <div class="flex shrink-0 items-center gap-1">
            <button
              :if={@state.status == :collapsed}
              id="mini-app-host-restore"
              type="button"
              phx-click="mini_app_restore"
              class="inline-flex size-9 cursor-pointer items-center justify-center border border-[color:var(--border-muted)] text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              aria-label="Restore mini app"
            >
              <.icon name="hero-chevron-up" class="size-4" />
            </button>

            <button
              :if={@state.status == :open}
              id="mini-app-host-collapse"
              type="button"
              phx-click="mini_app_collapse"
              class="inline-flex size-9 cursor-pointer items-center justify-center border border-[color:var(--border-muted)] text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              aria-label="Collapse mini app"
            >
              <.icon name="hero-chevron-down" class="size-4" />
            </button>

            <button
              :if={@state.status == :open}
              id="mini-app-host-expand"
              type="button"
              phx-click="mini_app_expand"
              class="hidden size-9 cursor-pointer items-center justify-center border border-[color:var(--border-muted)] text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal md:inline-flex"
              aria-label={if @state.expanded?, do: "Restore mini app size", else: "Expand mini app"}
            >
              <.icon
                name={
                  if @state.expanded?, do: "hero-arrows-pointing-in", else: "hero-arrows-pointing-out"
                }
                class="size-4"
              />
            </button>

            <button
              id="mini-app-host-close"
              type="button"
              phx-click="mini_app_close"
              class="inline-flex size-9 cursor-pointer items-center justify-center border border-[color:var(--border-muted)] text-[color:var(--text-secondary)] transition hover:border-[color:var(--danger)] hover:text-[color:var(--danger)] focus-visible:outline-none focus-brutal"
              aria-label="Close mini app"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
        </header>

        <section
          :if={@state.status == :open and @state.context_request}
          id="mini-app-context-consent"
          class="absolute inset-0 z-30 flex items-center justify-center bg-[color:var(--text-primary)]/60 p-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="mini-app-context-consent-title"
        >
          <div class="w-full max-w-sm border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-5 shadow-[6px_6px_0_var(--border-default)]">
            <div class="flex items-start gap-3">
              <div class="flex size-10 shrink-0 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--warning-subtle)]">
                <.icon name="hero-eye" class="size-5 text-[color:var(--warning)]" />
              </div>
              <div>
                <h2
                  id="mini-app-context-consent-title"
                  class="font-bold text-[color:var(--text-primary)]"
                >
                  Share public note context?
                </h2>
                <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
                  <span class="font-mono font-bold">{display_origin(@state.card.app_origin)}</span>
                  will receive this public note’s URL, text, author, mentions, and the exact app link.
                </p>
                <p class="mt-2 text-xs text-[color:var(--text-muted)]">
                  This approval applies to future launches of this app. It does not share your Egregoros identity.
                </p>
              </div>
            </div>

            <div class="mt-5 flex justify-end gap-2">
              <button
                id="mini-app-context-deny"
                type="button"
                phx-click="mini_app_context_deny"
                class="cursor-pointer border-2 border-[color:var(--border-default)] px-4 py-2 text-sm font-bold text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              >
                Not now
              </button>
              <button
                id="mini-app-context-approve"
                type="button"
                phx-click="mini_app_context_approve"
                class="cursor-pointer border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)] transition hover:shadow-[3px_3px_0_var(--accent)] focus-visible:outline-none focus-brutal"
              >
                Share context
              </button>
            </div>
          </div>
        </section>

        <section
          :if={@state.status == :open and @state.notification_request}
          id="mini-app-notification-consent"
          class="absolute inset-0 z-30 flex items-center justify-center bg-[color:var(--text-primary)]/60 p-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="mini-app-notification-consent-title"
        >
          <div class="w-full max-w-sm border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-5 shadow-[6px_6px_0_var(--border-default)]">
            <div class="flex items-start gap-3">
              <div class="flex size-10 shrink-0 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--accent-subtle)]">
                <.icon name="hero-bell" class="size-5 text-[color:var(--accent)]" />
              </div>
              <div class="min-w-0">
                <h2
                  id="mini-app-notification-consent-title"
                  class="font-bold text-[color:var(--text-primary)]"
                >
                  Allow transactional messages?
                </h2>
                <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
                  <span class="font-mono font-bold">{display_origin(@state.card.app_origin)}</span>
                  may send private ActivityPub notes that mention you from this exact actor:
                </p>
                <p class="mt-2 break-all font-mono text-xs text-[color:var(--text-primary)]">
                  {@state.notification_request.actor_url}
                </p>
                <p class="mt-2 text-xs text-[color:var(--text-muted)]">
                  This does not authorize public mentions, bypass blocks, or guarantee delivery. You can revoke it in Privacy settings.
                </p>
              </div>
            </div>

            <div class="mt-5 flex justify-end gap-2">
              <button
                id="mini-app-notification-deny"
                type="button"
                phx-click="mini_app_notification_deny"
                class="cursor-pointer border-2 border-[color:var(--border-default)] px-4 py-2 text-sm font-bold text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              >
                Don’t allow
              </button>
              <button
                id="mini-app-notification-approve"
                type="button"
                phx-click="mini_app_notification_approve"
                class="cursor-pointer border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)] transition hover:shadow-[3px_3px_0_var(--accent)] focus-visible:outline-none focus-brutal"
              >
                Allow messages
              </button>
            </div>
          </div>
        </section>

        <section
          :if={@state.status == :open and @state.auth_request}
          id="mini-app-auth-consent"
          class="absolute inset-0 z-30 flex items-center justify-center bg-[color:var(--text-primary)]/60 p-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="mini-app-auth-consent-title"
        >
          <div class="w-full max-w-sm border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-5 shadow-[6px_6px_0_var(--border-default)]">
            <div class="flex items-start gap-3">
              <div class="flex size-10 shrink-0 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--accent-subtle)]">
                <.icon name="hero-lock-closed" class="size-5 text-[color:var(--accent)]" />
              </div>
              <div>
                <h2
                  id="mini-app-auth-consent-title"
                  class="font-bold text-[color:var(--text-primary)]"
                >
                  Continue to authorization?
                </h2>
                <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
                  <span class="font-mono font-bold">{display_origin(@state.card.app_origin)}</span>
                  wants to open this instance’s OAuth approval screen in a separate window.
                </p>
                <p class="mt-2 text-xs text-[color:var(--text-muted)]">
                  The app will not receive your access token through this mini app window.
                </p>
              </div>
            </div>

            <div class="mt-5 flex justify-end gap-2">
              <button
                id="mini-app-auth-cancel"
                type="button"
                phx-click="mini_app_auth_cancel"
                class="cursor-pointer border-2 border-[color:var(--border-default)] px-4 py-2 text-sm font-bold text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              >
                Cancel
              </button>
              <button
                id="mini-app-auth-open"
                type="button"
                data-role="mini-app-auth-open"
                data-request-id={@state.auth_request.request_id}
                data-auth-url={@state.auth_request.authorization_url}
                class="cursor-pointer border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)] transition hover:shadow-[3px_3px_0_var(--accent)] focus-visible:outline-none focus-brutal"
              >
                Continue
              </button>
            </div>
          </div>
        </section>

        <section
          :if={@state.status == :open and @state.compose_request}
          id="mini-app-compose-sheet"
          class="absolute inset-0 z-30 flex flex-col bg-[color:var(--bg-base)]"
          role="dialog"
          aria-modal="true"
          aria-labelledby="mini-app-compose-title"
        >
          <header class="flex items-center justify-between border-b-2 border-[color:var(--border-default)] px-4 py-3">
            <div>
              <p class="font-mono text-[10px] font-bold uppercase tracking-widest text-[color:var(--accent)]">
                Mini app draft
              </p>
              <h2 id="mini-app-compose-title" class="font-bold text-[color:var(--text-primary)]">
                Review before posting
              </h2>
            </div>
            <button
              id="mini-app-compose-cancel"
              type="button"
              phx-click="mini_app_compose_cancel"
              class="inline-flex size-9 cursor-pointer items-center justify-center border border-[color:var(--border-muted)] text-[color:var(--text-secondary)] transition hover:border-[color:var(--danger)] hover:text-[color:var(--danger)] focus-visible:outline-none focus-brutal"
              aria-label="Discard mini app draft"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto p-4">
            <div class="mb-4 border-l-4 border-[color:var(--warning)] bg-[color:var(--warning-subtle)] p-3 text-xs leading-relaxed text-[color:var(--text-secondary)]">
              This draft came from <span class="font-mono font-bold">{display_origin(
                @state.card.app_origin
              )}</span>. Review and edit every field. Nothing is posted until you press the button below.
            </div>

            <.form
              for={@state.compose_request.form}
              id="mini-app-compose-form"
              phx-change="mini_app_compose_change"
              phx-submit="mini_app_compose_submit"
              class="space-y-4"
            >
              <.input
                field={@state.compose_request.form[:content]}
                type="textarea"
                label="Post text"
                rows="8"
              />
              <.input
                field={@state.compose_request.form[:spoiler_text]}
                type="text"
                label="Content warning"
              />
              <div class="grid grid-cols-2 gap-3">
                <.input
                  field={@state.compose_request.form[:visibility]}
                  type="select"
                  label="Visibility"
                  options={[
                    {"Public", "public"},
                    {"Unlisted", "unlisted"},
                    {"Followers", "followers"},
                    {"Direct", "direct"}
                  ]}
                />
                <.input
                  field={@state.compose_request.form[:language]}
                  type="text"
                  label="Language"
                  placeholder="e.g. en"
                />
              </div>

              <p
                :if={@state.compose_request.in_reply_to}
                id="mini-app-compose-reply-target"
                class="break-all border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] p-3 font-mono text-xs text-[color:var(--text-muted)]"
              >
                Replying to {@state.compose_request.in_reply_to}
              </p>

              <p
                :if={@state.compose_request.error}
                id="mini-app-compose-error"
                class="text-sm font-bold text-[color:var(--danger)]"
              >
                {@state.compose_request.error}
              </p>

              <button
                id="mini-app-compose-submit"
                type="submit"
                class="w-full cursor-pointer border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-3 text-sm font-bold text-[color:var(--bg-base)] transition hover:shadow-[4px_4px_0_var(--accent)] focus-visible:outline-none focus-brutal"
              >
                Post from Egregoros
              </button>
            </.form>
          </div>
        </section>

        <section
          :if={@state.status == :open and @state.external_request}
          id="mini-app-external-confirmation"
          class="absolute inset-0 z-30 flex items-center justify-center bg-[color:var(--text-primary)]/60 p-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="mini-app-external-title"
        >
          <div class="w-full max-w-sm border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-5 shadow-[6px_6px_0_var(--border-default)]">
            <h2 id="mini-app-external-title" class="font-bold text-[color:var(--text-primary)]">
              Leave Egregoros?
            </h2>
            <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
              <span class="font-mono font-bold">{display_origin(@state.card.app_origin)}</span>
              wants to open this external destination:
            </p>
            <p class="mt-3 break-all border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] p-3 font-mono text-xs text-[color:var(--text-primary)]">
              {@state.external_request.url}
            </p>

            <div class="mt-5 flex justify-end gap-2">
              <button
                id="mini-app-external-deny"
                type="button"
                phx-click="mini_app_external_deny"
                class="cursor-pointer border-2 border-[color:var(--border-default)] px-4 py-2 text-sm font-bold text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              >
                Stay here
              </button>
              <button
                id="mini-app-external-open"
                type="button"
                data-role="mini-app-external-open"
                data-external-url={@state.external_request.url}
                phx-click="mini_app_external_confirm"
                class="cursor-pointer border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)] transition hover:shadow-[3px_3px_0_var(--accent)] focus-visible:outline-none focus-brutal"
              >
                Open external site
              </button>
            </div>
          </div>
        </section>

        <section
          :if={
            (@state.status == :open and @state.wallet_request) &&
              @state.wallet_request.confirm? &&
              @state.wallet_request.method == "eth_requestAccounts"
          }
          id="mini-app-wallet-connection"
          class="absolute inset-0 z-30 flex items-center justify-center bg-[color:var(--text-primary)]/60 p-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="mini-app-wallet-title"
        >
          <div class="w-full max-w-sm border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-5 shadow-[6px_6px_0_var(--border-default)]">
            <h2 id="mini-app-wallet-title" class="font-bold text-[color:var(--text-primary)]">
              Connect wallet to this app?
            </h2>
            <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
              <span class="font-mono font-bold">{display_origin(@state.card.app_origin)}</span>
              will see only the public account addresses you select. This does not approve any signature or transaction.
            </p>
            <div class="mt-5 flex justify-end gap-2">
              <button
                id="mini-app-wallet-deny"
                type="button"
                phx-click="mini_app_wallet_deny"
                class="cursor-pointer border-2 border-[color:var(--border-default)] px-4 py-2 text-sm font-bold"
              >
                Not now
              </button>
              <button
                id="mini-app-wallet-connect"
                type="button"
                phx-click="mini_app_wallet_confirm"
                class="cursor-pointer border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)]"
              >
                Choose accounts
              </button>
            </div>
          </div>
        </section>

        <section
          :if={
            (@state.status == :open and @state.wallet_request) &&
              @state.wallet_request.confirm? &&
              @state.wallet_request.method in [
                "personal_sign",
                "eth_signTypedData_v4",
                "eth_sendTransaction"
              ]
          }
          id="mini-app-wallet-approval"
          data-method={@state.wallet_request.method}
          class="absolute inset-0 z-30 flex items-center justify-center bg-[color:var(--text-primary)]/60 p-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="mini-app-wallet-approval-title"
        >
          <div class="max-h-full w-full max-w-md overflow-y-auto border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-5 shadow-[6px_6px_0_var(--border-default)]">
            <h2 id="mini-app-wallet-approval-title" class="font-bold text-[color:var(--text-primary)]">
              Review wallet request
            </h2>
            <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
              <span class="font-mono font-bold">{display_origin(@state.card.app_origin)}</span>
              is requesting this exact action. Egregoros does not simulate its effects.
            </p>
            <div class="mt-4 space-y-3 border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] p-3 font-mono text-xs text-[color:var(--text-primary)]">
              <%= case @state.wallet_request.summary do %>
                <% %{kind: :personal_sign, message: message} -> %>
                  <p id="mini-app-wallet-review-message" class="break-all">{message}</p>
                <% %{kind: :typed_data} = summary -> %>
                  <p>Domain: {summary.domain || "(not declared)"}</p>
                  <p>Type: {summary.primary_type || "(not declared)"}</p>
                  <p>Chain: {summary.chain_id || "(not declared)"}</p>
                <% %{kind: :transaction} = summary -> %>
                  <p class="break-all">From: {summary.from}</p>
                  <p class="break-all">To: {summary.to || "(contract creation)"}</p>
                  <p>Value: {summary.value || "0x0"}</p>
                  <p>Gas: {summary.gas || "wallet estimate"}</p>
                  <p class="break-all">Data: {summary.data || "0x"}</p>
              <% end %>
            </div>
            <div class="mt-5 flex justify-end gap-2">
              <button
                id="mini-app-wallet-deny"
                type="button"
                phx-click="mini_app_wallet_deny"
                class="cursor-pointer border-2 border-[color:var(--border-default)] px-4 py-2 text-sm font-bold"
              >
                Reject
              </button>
              <button
                id="mini-app-wallet-approve"
                type="button"
                phx-click="mini_app_wallet_confirm"
                class="cursor-pointer border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)]"
              >
                Confirm in wallet
              </button>
            </div>
          </div>
        </section>

        <section
          :if={@state.status == :open and @state.wallet_incompatible?}
          id="mini-app-wallet-incompatible"
          class="absolute inset-0 z-40 flex items-center justify-center bg-[color:var(--bg-base)] p-6 text-center"
          role="alert"
        >
          <div class="max-w-sm">
            <.icon
              name="hero-exclamation-triangle"
              class="mx-auto size-10 text-[color:var(--warning)]"
            />
            <h2 class="mt-4 text-lg font-bold text-[color:var(--text-primary)]">
              Compatible wallet required
            </h2>
            <p class="mt-2 text-sm text-[color:var(--text-secondary)]">
              Connect an injected wallet on one of this app’s declared chains, then reopen it.
            </p>
          </div>
        </section>

        <div
          :if={@state.status == :open}
          class="relative min-h-0 flex-1 bg-white"
          data-role="mini-app-frame-container"
        >
          <div
            :if={!@state.ready? and !@state.load_error?}
            data-role="mini-app-loading"
            class="absolute inset-0 z-10 flex flex-col items-center justify-center gap-4 bg-[color:var(--bg-base)] p-8 text-center"
          >
            <div class="flex size-16 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] shadow-[4px_4px_0_var(--accent)]">
              <.icon name="hero-window" class="size-8 text-[color:var(--bg-base)]" />
            </div>
            <div>
              <p class="font-bold text-[color:var(--text-primary)]">Loading {@state.card.app_name}</p>
              <p class="mt-1 font-mono text-xs text-[color:var(--text-muted)]">
                Waiting for the app to become ready…
              </p>
            </div>
          </div>

          <div
            :if={@state.load_error?}
            id="mini-app-frame-error"
            class="absolute inset-0 z-20 flex flex-col items-center justify-center gap-5 bg-[color:var(--bg-base)] p-8 text-center"
            role="alert"
          >
            <div class="flex size-16 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--warning)] shadow-[4px_4px_0_var(--border-default)]">
              <.icon name="hero-exclamation-triangle" class="size-8 text-[color:var(--text-primary)]" />
            </div>
            <div class="max-w-sm">
              <p class="font-bold text-[color:var(--text-primary)]">
                {@state.card.app_name} did not become ready
              </p>
              <p class="mt-2 text-sm text-[color:var(--text-secondary)]">
                The app may block framing, be offline, or use an incompatible protocol. No host permission was granted.
              </p>
            </div>
            <div class="flex flex-wrap justify-center gap-2">
              <button
                id="mini-app-frame-retry"
                type="button"
                phx-click="mini_app_frame_retry"
                class="border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)]"
              >
                Retry
              </button>
              <button
                id="mini-app-frame-open-external"
                type="button"
                phx-click="mini_app_frame_external"
                class="border-2 border-[color:var(--border-default)] px-4 py-2 text-sm font-bold text-[color:var(--text-secondary)]"
              >
                Open externally
              </button>
            </div>
          </div>

          <iframe
            id="mini-app-frame"
            title={@state.card.app_name <> " mini app"}
            src={~p"/mini-apps/broker/#{@state.card.id}?launch_id=#{@state.launch_id}"}
            referrerpolicy="no-referrer"
            class={[
              "h-full w-full border-0 transition-opacity duration-200",
              if(@state.ready?, do: "opacity-100", else: "opacity-0")
            ]}
          >
          </iframe>
        </div>
      <% end %>
    </aside>
    """
  end

  defp handle_host_event("mini_app_open", %{"card_id" => card_id}, socket) do
    case Cards.get_active_by_id(card_id) do
      %Card{} = card ->
        wallet_declaration = Declarations.get_by_origin(card.app_origin)

        {:halt,
         Phoenix.Component.assign(socket, :mini_app_host, %{
           status: :open,
           expanded?: false,
           card: card,
           launch_id: launch_id(),
           ready?: false,
           load_error?: false,
           context_request: nil,
           notification_request: nil,
           auth_request: nil,
           oauth_authenticated?: false,
           compose_request: nil,
           external_request: nil,
           wallet_declaration: wallet_declaration,
           wallet_request: nil,
           wallet_incompatible?: false
         })}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_collapse", _params, socket) do
    {:halt, update_status(socket, :collapsed)}
  end

  defp handle_host_event("mini_app_restore", _params, socket) do
    {:halt, socket |> update_status(:open) |> update_ready(false)}
  end

  defp handle_host_event("mini_app_expand", _params, socket) do
    state = socket.assigns.mini_app_host

    {:halt,
     Phoenix.Component.assign(socket, :mini_app_host, %{state | expanded?: !state.expanded?})}
  end

  defp handle_host_event("mini_app_close", _params, socket) do
    {:halt, Phoenix.Component.assign(socket, :mini_app_host, closed_state())}
  end

  defp handle_host_event(
         "mini_app_context_request",
         %{"launch_id" => launch_id, "request_id" => request_id},
         socket
       ) do
    state = socket.assigns.mini_app_host

    if context_request_allowed?(state, launch_id, request_id) do
      {:halt, handle_context_request(socket, request_id)}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_context_approve", _params, socket) do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    with %{request_id: request_id} <- state.context_request,
         true <- is_binary(user_id),
         %Card{} = card <- Cards.get_active_by_id(state.card.id),
         {:ok, _consent} <- ContextConsents.grant(user_id, card.app_origin) do
      {:halt, release_context(socket, card, request_id)}
    else
      _ -> {:halt, deny_pending_context(socket, "unavailable")}
    end
  end

  defp handle_host_event("mini_app_context_deny", _params, socket) do
    {:halt, deny_pending_context(socket, "denied")}
  end

  defp handle_host_event(
         "mini_app_notification_permission_request",
         %{
           "launch_id" => launch_id,
           "request_id" => request_id,
           "action" => action
         },
         socket
       )
       when action in ["get", "request"] do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    if notification_request_allowed?(state, launch_id, request_id) do
      with true <- is_binary(user_id),
           true <- OAuthRegistrations.active_user_grant?(state.card.app_origin, user_id),
           {:ok, actor_url} <- Declarations.notification_actor(state.card.app_origin) do
        permission_state = NotificationConsents.state(user_id, state.card.app_origin)

        cond do
          action == "get" or permission_state == :granted ->
            {:halt,
             push_notification_permission_response(
               socket,
               request_id,
               permission_state,
               actor_url
             )}

          true ->
            request = %{request_id: request_id, actor_url: actor_url}

            {:halt,
             Phoenix.Component.assign(socket, :mini_app_host, %{
               state
               | notification_request: request
             })}
        end
      else
        false ->
          {:halt, push_notification_permission_error(socket, request_id, "auth_required")}

        _ ->
          {:halt, push_notification_permission_error(socket, request_id, "unavailable")}
      end
    else
      {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_notification_approve", _params, socket) do
    decide_notification_permission(socket, :granted)
  end

  defp handle_host_event("mini_app_notification_deny", _params, socket) do
    decide_notification_permission(socket, :denied)
  end

  defp handle_host_event(
         "mini_app_auth_request",
         %{"launch_id" => launch_id, "request_id" => request_id} = params,
         socket
       ) do
    state = socket.assigns.mini_app_host

    if auth_request_allowed?(state, launch_id, request_id) do
      auth_params = Map.drop(params, ["launch_id"])

      case AuthRequest.prepare(state.card.app_origin, auth_params) do
        {:ok, request} ->
          {:halt,
           Phoenix.Component.assign(socket, :mini_app_host, %{state | auth_request: request})}

        {:error, _reason} ->
          {:halt, push_auth_response(socket, request_id, "invalid_request")}
      end
    else
      {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_auth_cancel", _params, socket) do
    case socket.assigns.mini_app_host.auth_request do
      %{request_id: request_id} -> {:halt, push_auth_response(socket, request_id, "cancelled")}
      _ -> {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_auth_complete",
         %{"launch_id" => launch_id, "request_id" => request_id, "status" => status},
         socket
       )
       when status in ["success", "cancelled", "error"] do
    state = socket.assigns.mini_app_host

    if (state.launch_id == launch_id and state.auth_request) &&
         state.auth_request.request_id == request_id do
      authenticated? =
        status == "success" and
          OAuthRegistrations.active_user_grant?(
            state.card.app_origin,
            socket.assigns.mini_app_user_id
          )

      {:halt, %{accepted: true, authenticated: authenticated?},
       Phoenix.Component.assign(socket, :mini_app_host, %{
         state
         | auth_request: nil,
           oauth_authenticated?: authenticated?
       })}
    else
      {:halt, %{accepted: false}, socket}
    end
  end

  defp handle_host_event(
         "mini_app_compose_request",
         %{"launch_id" => launch_id, "call_id" => call_id, "draft" => draft},
         socket
       ) do
    state = socket.assigns.mini_app_host

    cond do
      not compose_request_base_allowed?(state, launch_id, call_id) ->
        {:halt, socket}

      not state.oauth_authenticated? ->
        {:halt, push_compose_response(socket, call_id, "auth_required")}

      not OAuthRegistrations.capability_allowed?(state.card.app_origin, "compose_note") ->
        {:halt, push_compose_response(socket, call_id, "unavailable")}

      true ->
        case ComposeDraft.prepare(state.card, draft) do
          {:ok, prepared} ->
            request_id = launch_id()

            compose_request = %{
              call_id: call_id,
              request_id: request_id,
              in_reply_to: prepared["in_reply_to"],
              form:
                prepared
                |> Map.take(~w(content spoiler_text language visibility))
                |> Phoenix.Component.to_form(as: :mini_app_post),
              error: nil
            }

            socket =
              socket
              |> Phoenix.Component.assign(:mini_app_host, %{
                state
                | compose_request: compose_request
              })
              |> Phoenix.LiveView.push_event("mini_app_compose_response", %{
                launch_id: state.launch_id,
                call_id: call_id,
                request_id: request_id,
                status: "accepted"
              })

            {:halt, socket}

          {:error, _reason} ->
            {:halt, push_compose_response(socket, call_id, "invalid_draft")}
        end
    end
  end

  defp handle_host_event(
         "mini_app_compose_change",
         %{"mini_app_post" => params},
         socket
       )
       when is_map(params) do
    state = socket.assigns.mini_app_host

    case state.compose_request do
      %{} = request ->
        form =
          params
          |> Map.take(~w(content spoiler_text language visibility))
          |> Phoenix.Component.to_form(as: :mini_app_post)

        {:halt,
         Phoenix.Component.assign(socket, :mini_app_host, %{
           state
           | compose_request: %{request | form: form, error: nil}
         })}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_compose_submit",
         %{"mini_app_post" => params},
         socket
       )
       when is_map(params) do
    {:halt, submit_compose(socket, params)}
  end

  defp handle_host_event("mini_app_compose_cancel", _params, socket) do
    state = socket.assigns.mini_app_host
    {:halt, Phoenix.Component.assign(socket, :mini_app_host, %{state | compose_request: nil})}
  end

  defp handle_host_event(
         "mini_app_external_request",
         %{"launch_id" => launch_id, "request_id" => request_id, "url" => url},
         socket
       ) do
    state = socket.assigns.mini_app_host

    with true <- host_action_allowed?(state, launch_id, request_id),
         {:ok, url} <- ExternalURL.validate(url) do
      {:halt,
       Phoenix.Component.assign(socket, :mini_app_host, %{
         state
         | external_request: %{request_id: request_id, url: url}
       })}
    else
      _ -> {:halt, push_external_response(socket, request_id, "invalid_request")}
    end
  end

  defp handle_host_event("mini_app_external_deny", _params, socket) do
    {:halt, finish_external_request(socket, "denied")}
  end

  defp handle_host_event("mini_app_external_confirm", _params, socket) do
    {:halt, finish_external_request(socket, "approved")}
  end

  defp handle_host_event(
         "mini_app_ready_timeout",
         %{"launch_id" => launch_id},
         socket
       ) do
    state = socket.assigns.mini_app_host

    if state.status in [:open, :collapsed] and state.launch_id == launch_id and not state.ready? do
      {:halt, Phoenix.Component.assign(socket, :mini_app_host, %{state | load_error?: true})}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_frame_retry", _params, socket) do
    state = socket.assigns.mini_app_host

    if state.status == :open and state.load_error? and active_card?(state.card) do
      launch_id = launch_id()

      socket =
        socket
        |> Phoenix.Component.assign(:mini_app_host, %{
          state
          | launch_id: launch_id,
            ready?: false,
            load_error?: false,
            auth_request: nil,
            oauth_authenticated?: false,
            context_request: nil,
            compose_request: nil,
            external_request: nil,
            wallet_request: nil
        })
        |> Phoenix.LiveView.push_event("mini_app_frame_reload", %{launch_id: launch_id})

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_frame_external", _params, socket) do
    state = socket.assigns.mini_app_host

    if state.status == :open and state.load_error? and active_card?(state.card) do
      request = %{request_id: launch_id(), url: state.card.launch_url, host_only?: true}

      {:halt,
       Phoenix.Component.assign(socket, :mini_app_host, %{state | external_request: request})}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_close_request",
         %{"launch_id" => launch_id, "request_id" => request_id},
         socket
       ) do
    state = socket.assigns.mini_app_host

    if state.status != :closed and state.launch_id == launch_id and
         valid_request_id?(request_id) and active_card?(state.card) do
      {:halt, Phoenix.Component.assign(socket, :mini_app_host, closed_state())}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_wallet_request",
         %{
           "launch_id" => launch_id,
           "request_id" => request_id,
           "method" => method,
           "params" => []
         },
         socket
       )
       when method in ["eth_accounts", "eth_chainId", "eth_requestAccounts"] do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    if wallet_request_allowed?(state, launch_id, request_id, user_id) do
      handle_wallet_request(socket, request_id, method, user_id)
    else
      {:halt, push_wallet_rejection(socket, request_id, 4100, "Wallet access unavailable")}
    end
  end

  defp handle_host_event(
         "mini_app_wallet_request",
         %{
           "launch_id" => launch_id,
           "request_id" => request_id,
           "method" => method,
           "params" => params
         },
         socket
       )
       when method in ["personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"] do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    with true <- wallet_request_allowed?(state, launch_id, request_id, user_id),
         approved when approved != [] <-
           WalletConnections.accounts(user_id, state.card.app_origin),
         {:ok, request} <- WalletRequest.validate(method, params, approved) do
      pending = Map.merge(request, %{request_id: request_id, confirm?: false})

      socket =
        socket
        |> Phoenix.Component.assign(:mini_app_host, %{state | wallet_request: pending})
        |> Phoenix.LiveView.push_event("mini_app_wallet_preflight", %{
          launch_id: state.launch_id,
          request_id: request_id
        })

      {:halt, socket}
    else
      _other ->
        {:halt, push_wallet_rejection(socket, request_id, 4100, "Wallet access unavailable")}
    end
  end

  defp handle_host_event(
         "mini_app_wallet_preflight_result",
         %{
           "launch_id" => launch_id,
           "request_id" => request_id,
           "status" => "ok",
           "chain_id" => chain_id,
           "accounts" => accounts
         },
         socket
       ) do
    state = socket.assigns.mini_app_host
    current = normalize_wallet_accounts(accounts)

    case state.wallet_request do
      %{request_id: ^request_id, account: account, confirm?: false} = request
      when state.launch_id == launch_id ->
        if valid_chain_id?(chain_id) and wallet_chain_allowed?(state, chain_id) and
             String.downcase(account) in current do
          pending =
            Map.merge(request, %{
              confirm?: true,
              expected_chain_id: chain_id,
              expected_accounts: current
            })

          {:halt,
           Phoenix.Component.assign(socket, :mini_app_host, %{state | wallet_request: pending})}
        else
          {:halt, push_wallet_error(socket, request_id, 4901, "Wallet account or chain changed")}
        end

      _other ->
        {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_wallet_preflight_result",
         %{"launch_id" => launch_id, "request_id" => request_id, "status" => "error"},
         socket
       ) do
    state = socket.assigns.mini_app_host

    if (state.launch_id == launch_id and state.wallet_request) &&
         state.wallet_request.request_id == request_id do
      {:halt, push_wallet_error(socket, request_id, 4900, "Wallet preflight failed")}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_wallet_confirm", _params, socket) do
    state = socket.assigns.mini_app_host

    case state.wallet_request do
      %{request_id: request_id, method: "eth_requestAccounts", confirm?: true} = request ->
        socket =
          socket
          |> Phoenix.Component.assign(:mini_app_host, %{
            state
            | wallet_request: %{request | confirm?: false}
          })
          |> push_wallet_execute(request_id, "eth_requestAccounts")

        {:halt, socket}

      %{
        request_id: request_id,
        method: method,
        params: params,
        fingerprint: fingerprint,
        account: account,
        confirm?: true,
        expected_chain_id: chain_id,
        expected_accounts: accounts
      } = request ->
        user_id = socket.assigns.mini_app_user_id
        approved = WalletConnections.accounts(user_id, state.card.app_origin)

        with true <- active_card?(state.card),
             true <- Declarations.wallet_enabled?(state.card.app_origin),
             true <- String.downcase(account) in approved,
             {:ok, validated} <- WalletRequest.validate(method, params, approved),
             true <- validated.fingerprint == fingerprint do
          socket =
            socket
            |> Phoenix.Component.assign(:mini_app_host, %{
              state
              | wallet_request: %{request | confirm?: false}
            })
            |> push_wallet_execute(request_id, method, params,
              expected_chain_id: chain_id,
              expected_accounts: accounts
            )

          {:halt, socket}
        else
          _other ->
            {:halt, push_wallet_error(socket, request_id, 4100, "Wallet access unavailable")}
        end

      _ ->
        {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_wallet_deny", _params, socket) do
    case socket.assigns.mini_app_host.wallet_request do
      %{request_id: request_id, method: "eth_requestAccounts"} ->
        {:halt, push_wallet_error(socket, request_id, 4001, "User rejected wallet connection")}

      %{request_id: request_id} ->
        {:halt, push_wallet_error(socket, request_id, 4001, "User rejected wallet request")}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_wallet_execution_result",
         %{"launch_id" => launch_id, "request_id" => request_id, "status" => status} = params,
         socket
       )
       when status in ["ok", "error"] do
    state = socket.assigns.mini_app_host

    if (state.launch_id == launch_id and state.wallet_request) &&
         state.wallet_request.request_id == request_id do
      {:halt, finish_wallet_execution(socket, params)}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_wallet_availability",
         %{"launch_id" => launch_id, "compatible" => compatible},
         socket
       )
       when is_boolean(compatible) do
    state = socket.assigns.mini_app_host

    if state.status == :open and state.launch_id == launch_id and
         wallet_value(state, :wallet_evm_required, false) do
      {:halt,
       Phoenix.Component.assign(socket, :mini_app_host, %{
         state
         | wallet_incompatible?: not compatible
       })}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event(event, %{"launch_id" => launch_id}, socket)
       when event in ["mini_app_loading", "mini_app_ready"] do
    state = socket.assigns.mini_app_host

    if state.status in [:open, :collapsed] and state.launch_id == launch_id and
         active_card?(state.card) do
      {:halt,
       Phoenix.Component.assign(socket, :mini_app_host, %{
         state
         | ready?: event == "mini_app_ready",
           load_error?: false,
           auth_request: if(event == "mini_app_loading", do: nil, else: state.auth_request),
           notification_request:
             if(event == "mini_app_loading", do: nil, else: state.notification_request),
           oauth_authenticated?:
             if(event == "mini_app_loading", do: false, else: state.oauth_authenticated?),
           compose_request: if(event == "mini_app_loading", do: nil, else: state.compose_request),
           external_request:
             if(event == "mini_app_loading", do: nil, else: state.external_request),
           wallet_request: if(event == "mini_app_loading", do: nil, else: state.wallet_request)
       })}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event(event, _params, socket)
       when event in [
              "mini_app_notification_permission_request",
              "mini_app_wallet_request",
              "mini_app_wallet_preflight_result",
              "mini_app_wallet_execution_result",
              "mini_app_ready_timeout"
            ],
       do: {:halt, socket}

  defp handle_host_event(_event, _params, socket), do: {:cont, socket}

  defp update_status(socket, status) do
    state = socket.assigns.mini_app_host

    if state.card do
      Phoenix.Component.assign(socket, :mini_app_host, %{state | status: status})
    else
      socket
    end
  end

  defp update_ready(socket, ready?) do
    state = socket.assigns.mini_app_host
    Phoenix.Component.assign(socket, :mini_app_host, %{state | ready?: ready?})
  end

  defp active_card?(%Card{id: id}), do: match?(%Card{}, Cards.get_active_by_id(id))
  defp active_card?(_card), do: false

  defp launch_id do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp closed_state do
    %{
      status: :closed,
      expanded?: false,
      card: nil,
      launch_id: nil,
      ready?: false,
      load_error?: false,
      context_request: nil,
      auth_request: nil,
      notification_request: nil,
      oauth_authenticated?: false,
      compose_request: nil,
      external_request: nil,
      wallet_declaration: nil,
      wallet_request: nil,
      wallet_incompatible?: false
    }
  end

  defp context_request_allowed?(state, launch_id, request_id) do
    state.status == :open and state.ready? and state.launch_id == launch_id and
      is_nil(state.compose_request) and is_nil(state.external_request) and
      is_nil(state.wallet_request) and is_nil(state.notification_request) and
      valid_request_id?(request_id) and active_card?(state.card)
  end

  defp auth_request_allowed?(state, launch_id, request_id) do
    state.status == :open and state.ready? and state.launch_id == launch_id and
      is_nil(state.auth_request) and is_nil(state.context_request) and
      is_nil(state.compose_request) and is_nil(state.external_request) and
      is_nil(state.wallet_request) and is_nil(state.notification_request) and
      valid_request_id?(request_id) and active_card?(state.card)
  end

  defp notification_request_allowed?(state, launch_id, request_id) do
    host_action_allowed?(state, launch_id, request_id) and
      is_nil(state.notification_request) and
      match?({:ok, _actor_url}, Declarations.notification_actor(state.card.app_origin))
  end

  defp wallet_request_allowed?(state, launch_id, request_id, user_id) do
    host_action_allowed?(state, launch_id, request_id) and is_binary(user_id) and
      Declarations.wallet_enabled?(state.card.app_origin)
  end

  defp compose_request_base_allowed?(state, launch_id, call_id) do
    state.status == :open and state.ready? and state.launch_id == launch_id and
      is_nil(state.auth_request) and is_nil(state.context_request) and
      is_nil(state.compose_request) and is_nil(state.external_request) and
      is_nil(state.wallet_request) and is_nil(state.notification_request) and
      valid_request_id?(call_id) and active_card?(state.card)
  end

  defp host_action_allowed?(state, launch_id, request_id) do
    state.status == :open and state.ready? and state.launch_id == launch_id and
      is_nil(state.auth_request) and is_nil(state.context_request) and
      is_nil(state.compose_request) and is_nil(state.external_request) and
      is_nil(state.wallet_request) and is_nil(state.notification_request) and
      valid_request_id?(request_id) and active_card?(state.card)
  end

  defp valid_request_id?(request_id) when is_binary(request_id) do
    byte_size(request_id) <= 64 and String.match?(request_id, ~r/^[A-Za-z0-9_-]+$/)
  end

  defp valid_request_id?(_request_id), do: false

  defp decide_notification_permission(socket, decision) when decision in [:granted, :denied] do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    with %{request_id: request_id, actor_url: actor_url} <- state.notification_request,
         true <- is_binary(user_id),
         true <- OAuthRegistrations.active_user_grant?(state.card.app_origin, user_id),
         {:ok, ^actor_url} <- Declarations.notification_actor(state.card.app_origin),
         {:ok, _consent} <-
           NotificationConsents.decide(user_id, state.card.app_origin, decision) do
      {:halt, push_notification_permission_response(socket, request_id, decision, actor_url)}
    else
      false ->
        request_id = state.notification_request && state.notification_request.request_id
        {:halt, push_notification_permission_error(socket, request_id, "auth_required")}

      _ ->
        request_id = state.notification_request && state.notification_request.request_id
        {:halt, push_notification_permission_error(socket, request_id, "unavailable")}
    end
  end

  defp push_notification_permission_response(socket, request_id, state_name, actor_url) do
    state = socket.assigns.mini_app_host

    socket
    |> Phoenix.Component.assign(:mini_app_host, %{state | notification_request: nil})
    |> Phoenix.LiveView.push_event("mini_app_notification_permission_response", %{
      launch_id: state.launch_id,
      request_id: request_id,
      status: "ok",
      state: Atom.to_string(state_name),
      actor_url: actor_url
    })
  end

  defp push_notification_permission_error(socket, request_id, status) do
    state = socket.assigns.mini_app_host

    socket
    |> Phoenix.Component.assign(:mini_app_host, %{state | notification_request: nil})
    |> Phoenix.LiveView.push_event("mini_app_notification_permission_response", %{
      launch_id: state.launch_id,
      request_id: request_id,
      status: status
    })
  end

  defp handle_context_request(socket, request_id) do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    cond do
      not is_binary(user_id) ->
        push_context_response(socket, request_id, "unavailable", nil)

      ContextConsents.approved?(user_id, state.card.app_origin) ->
        release_context(socket, state.card, request_id)

      true ->
        Phoenix.Component.assign(socket, :mini_app_host, %{
          state
          | context_request: %{request_id: request_id}
        })
    end
  end

  defp release_context(socket, card, request_id) do
    case LaunchContext.for_card(card) do
      {:ok, context} -> push_context_response(socket, request_id, "ok", context)
      _ -> push_context_response(socket, request_id, "unavailable", nil)
    end
  end

  defp deny_pending_context(socket, status) do
    state = socket.assigns.mini_app_host

    case state.context_request do
      %{request_id: request_id} -> push_context_response(socket, request_id, status, nil)
      _ -> socket
    end
  end

  defp push_context_response(socket, request_id, status, context) do
    state = socket.assigns.mini_app_host

    socket
    |> Phoenix.Component.assign(:mini_app_host, %{state | context_request: nil})
    |> Phoenix.LiveView.push_event("mini_app_context_response", %{
      launch_id: state.launch_id,
      request_id: request_id,
      status: status,
      context: context
    })
  end

  defp push_auth_response(socket, request_id, status) do
    state = socket.assigns.mini_app_host

    socket
    |> Phoenix.Component.assign(:mini_app_host, %{state | auth_request: nil})
    |> Phoenix.LiveView.push_event("mini_app_auth_response", %{
      launch_id: state.launch_id,
      request_id: request_id,
      status: status
    })
  end

  defp push_compose_response(socket, call_id, status) do
    state = socket.assigns.mini_app_host

    Phoenix.LiveView.push_event(socket, "mini_app_compose_response", %{
      launch_id: state.launch_id,
      call_id: call_id,
      status: status
    })
  end

  defp finish_external_request(socket, status) do
    state = socket.assigns.mini_app_host

    case state.external_request do
      %{request_id: _request_id, host_only?: true} ->
        Phoenix.Component.assign(socket, :mini_app_host, %{state | external_request: nil})

      %{request_id: request_id} ->
        socket
        |> Phoenix.Component.assign(:mini_app_host, %{state | external_request: nil})
        |> Phoenix.LiveView.push_event("mini_app_external_response", %{
          launch_id: state.launch_id,
          request_id: request_id,
          status: status
        })

      _ ->
        socket
    end
  end

  defp push_external_response(socket, request_id, status) do
    state = socket.assigns.mini_app_host

    Phoenix.LiveView.push_event(socket, "mini_app_external_response", %{
      launch_id: state.launch_id,
      request_id: request_id,
      status: status
    })
  end

  defp handle_wallet_request(socket, request_id, "eth_accounts", user_id) do
    state = socket.assigns.mini_app_host

    if WalletConnections.connected?(user_id, state.card.app_origin) do
      {:halt, begin_wallet_execution(socket, request_id, "eth_accounts")}
    else
      {:halt, push_wallet_result(socket, request_id, [])}
    end
  end

  defp handle_wallet_request(socket, request_id, "eth_chainId", _user_id) do
    {:halt, begin_wallet_execution(socket, request_id, "eth_chainId")}
  end

  defp handle_wallet_request(socket, request_id, "eth_requestAccounts", user_id) do
    state = socket.assigns.mini_app_host

    if WalletConnections.connected?(user_id, state.card.app_origin) do
      {:halt, begin_wallet_execution(socket, request_id, "eth_accounts")}
    else
      request = %{request_id: request_id, method: "eth_requestAccounts", confirm?: true}

      {:halt,
       Phoenix.Component.assign(socket, :mini_app_host, %{state | wallet_request: request})}
    end
  end

  defp begin_wallet_execution(socket, request_id, method) do
    state = socket.assigns.mini_app_host
    request = %{request_id: request_id, method: method, confirm?: false}

    socket
    |> Phoenix.Component.assign(:mini_app_host, %{state | wallet_request: request})
    |> push_wallet_execute(request_id, method, [])
  end

  defp push_wallet_execute(socket, request_id, method),
    do: push_wallet_execute(socket, request_id, method, [])

  defp push_wallet_execute(socket, request_id, method, params, extra \\ []) do
    state = socket.assigns.mini_app_host

    payload = %{
      launch_id: state.launch_id,
      request_id: request_id,
      method: method,
      params: params
    }

    Phoenix.LiveView.push_event(
      socket,
      "mini_app_wallet_execute",
      Map.merge(payload, Map.new(extra))
    )
  end

  defp finish_wallet_execution(socket, %{"status" => "error"} = params) do
    request_id = socket.assigns.mini_app_host.wallet_request.request_id
    code = normalize_wallet_error_code(Map.get(params, "code"))
    push_wallet_error(socket, request_id, code, "Wallet request failed")
  end

  defp finish_wallet_execution(socket, %{"status" => "ok", "result" => result}) do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    case state.wallet_request.method do
      "eth_chainId" ->
        if valid_chain_id?(result) do
          push_wallet_result(socket, state.wallet_request.request_id, result)
        else
          push_wallet_error(
            socket,
            state.wallet_request.request_id,
            -32603,
            "Invalid wallet response"
          )
        end

      "eth_requestAccounts" ->
        case WalletConnections.connect(user_id, state.card.app_origin, List.wrap(result)) do
          {:ok, connection} ->
            push_wallet_result(socket, state.wallet_request.request_id, connection.accounts)

          _ ->
            push_wallet_error(
              socket,
              state.wallet_request.request_id,
              -32603,
              "Invalid wallet response"
            )
        end

      "eth_accounts" ->
        approved = WalletConnections.accounts(user_id, state.card.app_origin)
        current = normalize_wallet_accounts(result)

        push_wallet_result(
          socket,
          state.wallet_request.request_id,
          Enum.filter(approved, &(&1 in current))
        )

      method when method in ["personal_sign", "eth_signTypedData_v4"] ->
        if valid_signature?(result) do
          push_wallet_result(socket, state.wallet_request.request_id, result)
        else
          push_wallet_error(
            socket,
            state.wallet_request.request_id,
            -32603,
            "Invalid wallet response"
          )
        end

      "eth_sendTransaction" ->
        if valid_transaction_hash?(result) do
          push_wallet_result(socket, state.wallet_request.request_id, result)
        else
          push_wallet_error(
            socket,
            state.wallet_request.request_id,
            -32603,
            "Invalid wallet response"
          )
        end
    end
  end

  defp finish_wallet_execution(socket, _params) do
    request_id = socket.assigns.mini_app_host.wallet_request.request_id
    push_wallet_error(socket, request_id, -32603, "Invalid wallet response")
  end

  defp push_wallet_result(socket, request_id, result) do
    state = socket.assigns.mini_app_host

    socket
    |> Phoenix.Component.assign(:mini_app_host, %{state | wallet_request: nil})
    |> Phoenix.LiveView.push_event("mini_app_wallet_response", %{
      launch_id: state.launch_id,
      request_id: request_id,
      result: result
    })
  end

  defp push_wallet_error(socket, request_id, code, message) do
    state = socket.assigns.mini_app_host

    socket
    |> Phoenix.Component.assign(:mini_app_host, %{state | wallet_request: nil})
    |> Phoenix.LiveView.push_event("mini_app_wallet_response", %{
      launch_id: state.launch_id,
      request_id: request_id,
      error: %{code: code, message: message}
    })
  end

  defp push_wallet_rejection(socket, request_id, code, message) do
    state = socket.assigns.mini_app_host

    Phoenix.LiveView.push_event(socket, "mini_app_wallet_response", %{
      launch_id: state.launch_id,
      request_id: request_id,
      error: %{code: code, message: message}
    })
  end

  defp normalize_wallet_error_code(code) when is_integer(code) and code in -32_768..49_999,
    do: code

  defp normalize_wallet_error_code(_code), do: 4001

  defp valid_chain_id?(value) when is_binary(value),
    do: String.match?(value, ~r/^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/)

  defp valid_chain_id?(_value), do: false

  defp wallet_chain_allowed?(state, chain_id) do
    required = wallet_value(state, :wallet_evm_required_chains, [])
    required == [] or evm_chain_reference(chain_id) in required
  end

  defp evm_chain_reference("0x" <> encoded) do
    case Integer.parse(encoded, 16) do
      {chain_id, ""} -> "eip155:#{chain_id}"
      _other -> nil
    end
  end

  defp valid_signature?(value) when is_binary(value),
    do: String.match?(value, ~r/^0x[0-9a-fA-F]{130}$/)

  defp valid_signature?(_value), do: false

  defp valid_transaction_hash?(value) when is_binary(value),
    do: String.match?(value, ~r/^0x[0-9a-fA-F]{64}$/)

  defp valid_transaction_hash?(_value), do: false

  defp normalize_wallet_accounts(accounts) when is_list(accounts) do
    accounts
    |> Enum.filter(&(is_binary(&1) and String.match?(&1, ~r/^0x[0-9a-fA-F]{40}$/)))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.take(16)
  end

  defp normalize_wallet_accounts(_accounts), do: []

  defp submit_compose(socket, params) do
    state = socket.assigns.mini_app_host

    with %{request_id: request_id} = request <- state.compose_request,
         true <- state.oauth_authenticated?,
         true <- active_card?(state.card),
         true <- OAuthRegistrations.capability_allowed?(state.card.app_origin, "compose_note"),
         %User{} = user <- Users.get(socket.assigns.mini_app_user_id),
         :ok <- reply_target_still_allowed(state.card, request.in_reply_to),
         {:ok, publish} <- ComposeDraft.validate_form(params),
         {:ok, create} <-
           Publish.post_note(user, publish.content,
             visibility: publish.visibility,
             spoiler_text: publish.spoiler_text,
             language: publish.language,
             in_reply_to: request.in_reply_to
           ),
         id when is_binary(id) <- create.object do
      socket
      |> Phoenix.Component.assign(:mini_app_host, %{state | compose_request: nil})
      |> Phoenix.LiveView.push_event("mini_app_compose_published", %{
        launch_id: state.launch_id,
        request_id: request_id,
        id: id,
        scope: publish.scope
      })
    else
      _ -> put_compose_error(socket, "Could not post. Review the draft and try again.")
    end
  end

  defp reply_target_still_allowed(_card, nil), do: :ok

  defp reply_target_still_allowed(card, in_reply_to) do
    case ComposeDraft.prepare(card, %{"inReplyTo" => in_reply_to}) do
      {:ok, _prepared} -> :ok
      _ -> {:error, :invalid_reply_target}
    end
  end

  defp put_compose_error(socket, message) do
    state = socket.assigns.mini_app_host

    case state.compose_request do
      %{} = request ->
        Phoenix.Component.assign(socket, :mini_app_host, %{
          state
          | compose_request: %{request | error: message}
        })

      _ ->
        socket
    end
  end

  defp host_classes(%{status: :closed}), do: "hidden"

  defp host_classes(%{status: :collapsed}) do
    "fixed inset-x-4 bottom-[calc(1rem+env(safe-area-inset-bottom))] z-[60] flex border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] shadow-[6px_6px_0_var(--border-default)] md:bottom-4 md:left-auto md:w-80"
  end

  defp host_classes(%{status: :open, expanded?: true}) do
    "fixed inset-0 z-[60] flex flex-col border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] shadow-[8px_8px_0_var(--border-default)] md:inset-6 md:p-0"
  end

  defp host_classes(%{status: :open}) do
    "fixed inset-0 z-[60] flex flex-col border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] shadow-[8px_8px_0_var(--border-default)] md:inset-auto md:bottom-6 md:right-6 md:h-[min(695px,calc(100vh-3rem))] md:w-[min(424px,calc(100vw-3rem))] md:p-0"
  end

  defp card_value(%{card: %Card{} = card}, field), do: Map.get(card, field)
  defp card_value(_state, _field), do: nil

  defp wallet_value(%{wallet_declaration: declaration}, field, default)
       when not is_nil(declaration) do
    Map.get(declaration, field, default)
  end

  defp wallet_value(_state, _field, default), do: default

  defp display_origin(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{host: host, port: port} when is_binary(host) and port not in [nil, 443] ->
        "#{host}:#{port}"

      %URI{host: host} when is_binary(host) ->
        host

      _ ->
        origin
    end
  end
end
