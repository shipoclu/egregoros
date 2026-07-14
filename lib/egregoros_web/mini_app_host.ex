defmodule EgregorosWeb.MiniAppHost do
  @moduledoc false

  use EgregorosWeb, :html

  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.AuthRequest
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.ComposeDraft
  alias Egregoros.MiniApps.ContextConsents
  alias Egregoros.MiniApps.Declarations
  alias Egregoros.MiniApps.DeveloperLaunches
  alias Egregoros.MiniApps.ExternalURL
  alias Egregoros.MiniApps.GrantLock
  alias Egregoros.MiniApps.LaunchContext
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.Permissions
  alias Egregoros.MiniApps.WalletConnections
  alias Egregoros.MiniApps.WalletRequest
  alias Egregoros.OAuth
  alias Egregoros.Publish
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Users

  @broker_events [
    "mini_app_ready",
    "mini_app_context_request",
    "mini_app_notification_permission_request",
    "mini_app_auth_request",
    "mini_app_compose_request",
    "mini_app_close_request",
    "mini_app_external_request",
    "mini_app_wallet_request"
  ]
  @broker_request_events @broker_events -- ["mini_app_ready"]
  @broker_outstanding_events @broker_request_events -- ["mini_app_close_request"]
  @broker_max_message_bytes 384 * 1024
  @broker_max_total_bytes 2 * 1024 * 1024
  @broker_max_messages 256
  @broker_max_requests 128
  @broker_rate_capacity 40
  @broker_rate_per_second 20

  def on_mount(:default, _params, session, socket) do
    user_id = Map.get(session, "user_id")
    if Phoenix.LiveView.connected?(socket), do: Permissions.subscribe(user_id)

    socket =
      socket
      |> Phoenix.Component.assign(:mini_app_host, closed_state())
      |> Phoenix.Component.assign(:mini_app_user_id, user_id)
      |> Phoenix.Component.assign(:mini_app_developer_check, nil)
      |> Phoenix.Component.assign(:mini_app_developer_card_id, nil)
      |> Phoenix.LiveView.attach_hook(
        :mini_app_broker_budget,
        :handle_event,
        &handle_broker_event/3
      )
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

  defp handle_broker_event(event, %{"launch_id" => launch_id} = params, socket)
       when event in @broker_events do
    state = socket.assigns.mini_app_host

    cond do
      state.status not in [:open, :collapsed] or state.launch_id != launch_id ->
        {:halt, socket}

      event in @broker_request_events and not state.ready? ->
        {:halt, socket}

      true ->
        case consume_broker_budget(state.broker_budget, event, params) do
          {:ok, budget} ->
            pending? = event in @broker_outstanding_events and host_request_pending?(state)

            state =
              if not pending? and state.status == :collapsed and
                   event in @broker_outstanding_events,
                 do: %{state | status: :open},
                 else: state

            socket =
              Phoenix.Component.assign(socket, :mini_app_host, %{state | broker_budget: budget})

            if pending?,
              do: {:halt, reject_concurrent_request(socket, event, params)},
              else: {:cont, socket}

          {:error, _reason} ->
            {:halt, Phoenix.Component.assign(socket, :mini_app_host, closed_state())}
        end
    end
  end

  defp handle_broker_event(event, _params, socket) when event in @broker_events,
    do: {:halt, socket}

  defp handle_broker_event(_event, _params, socket), do: {:cont, socket}

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
      data-launch-info={launch_info_json(@state)}
      data-frame-title={if(@state.card, do: @state.card.app_name <> " mini app")}
      data-frame-src={broker_path(@state)}
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
      <.frame_island state={@state} />

      <%= if @state.status != :closed and @state.card do %>
        <header class="order-1 flex h-14 shrink-0 items-center justify-between gap-3 border-b-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3">
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
                  if @state.expanded?,
                    do: "hero-arrows-pointing-in",
                    else: "hero-arrows-pointing-out"
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
                  Share additional public note context?
                </h2>
                <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
                  <span class="font-mono font-bold">{display_origin(@state.card.app_origin)}</span>
                  already received this public note’s Fediverse ID and exact app link when you opened it. If you approve, it will additionally receive the note’s text, author, and mentions.
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
                data-auth-state={@state.auth_request.relay_state}
                data-auth-url={@state.auth_request.authorization_url}
                data-auth-completion-mode={@state.auth_request.completion_mode}
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
            <h2
              id="mini-app-wallet-approval-title"
              class="font-bold text-[color:var(--text-primary)]"
            >
              Review wallet request
            </h2>
            <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
              <span class="font-mono font-bold">{display_origin(@state.card.app_origin)}</span>
              is requesting this exact action. Egregoros does not simulate its effects.
            </p>
            <div class="mt-4 space-y-3 border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] p-3 font-mono text-xs text-[color:var(--text-primary)]">
              <p class="break-all">Account: {@state.wallet_request.account}</p>
              <p>Chain: {@state.wallet_request.expected_chain_id}</p>
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
              <pre
                id="mini-app-wallet-review-exact"
                class="max-h-40 overflow-auto whitespace-pre-wrap break-all border-t border-[color:var(--border-muted)] pt-3"
              >{@state.wallet_request.review_json}</pre>
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
      <% end %>
    </aside>
    """
  end

  defp frame_island(assigns) do
    ~H"""
    <div
      id="mini-app-frame-container"
      data-role="mini-app-frame-container"
      data-active={to_string(@state.status in [:open, :collapsed] and not is_nil(@state.card))}
      data-state={@state.status}
      data-ready={to_string(@state.ready?)}
      data-load-error={to_string(@state.load_error?)}
      phx-update="ignore"
      class="order-2 relative min-h-0 flex-1 bg-white"
    >
      <div
        data-role="mini-app-loading"
        class="absolute inset-0 z-10 flex flex-col items-center justify-center gap-4 bg-[color:var(--bg-base)] p-8 text-center"
      >
        <div class="flex size-16 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] shadow-[4px_4px_0_var(--accent)]">
          <.icon name="hero-window" class="size-8 text-[color:var(--bg-base)]" />
        </div>
        <div>
          <p class="font-bold text-[color:var(--text-primary)]">Loading mini app</p>
          <p class="mt-1 font-mono text-xs text-[color:var(--text-muted)]">
            Waiting for the app to become ready…
          </p>
        </div>
      </div>

      <div
        id="mini-app-frame-error"
        class="absolute inset-0 z-20 hidden flex-col items-center justify-center gap-5 bg-[color:var(--bg-base)] p-8 text-center"
        role="alert"
      >
        <div class="flex size-16 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--warning)] shadow-[4px_4px_0_var(--border-default)]">
          <.icon name="hero-exclamation-triangle" class="size-8 text-[color:var(--text-primary)]" />
        </div>
        <div class="max-w-sm">
          <p class="font-bold text-[color:var(--text-primary)]">
            Mini app did not become ready
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

      <div id="mini-app-frame-shell" class="h-full w-full border-0"></div>
    </div>
    """
  end

  defp handle_host_event(
         "mini_app_open",
         %{"card_id" => card_id, "resolution_token" => resolution_token},
         socket
       ) do
    current_user = Users.get(socket.assigns.mini_app_user_id)

    with %Card{} = card <- active_card(card_id, resolution_token, current_user),
         {:ok, launch_info} <- launch_info(card) do
      wallet_declaration =
        if developer_card?(card), do: nil, else: Declarations.get_by_origin(card.app_origin)

      socket =
        if developer_card?(card) do
          socket
          |> Phoenix.Component.assign(:mini_app_developer_check, :pending)
          |> Phoenix.Component.assign(:mini_app_developer_card_id, card.id)
        else
          socket
        end

      {:halt,
       Phoenix.Component.assign(socket, :mini_app_host, %{
         status: :open,
         expanded?: false,
         card: card,
         launch_info: launch_info,
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
         wallet_incompatible?: false,
         broker_budget: new_broker_budget()
       })}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_open", _params, socket), do: {:halt, socket}

  defp handle_host_event("mini_app_collapse", _params, socket) do
    {:halt, update_status(socket, :collapsed)}
  end

  defp handle_host_event("mini_app_restore", _params, socket) do
    {:halt, update_status(socket, :open)}
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
         %Card{} = card <-
           Cards.get_active_by_id(state.card.id, state.card.resolution_token),
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
         %{"launch_id" => launch_id, "request_id" => request_id, "status" => status} = params,
         socket
       )
       when status in ["success", "cancelled", "error"] do
    state = socket.assigns.mini_app_host

    if (state.launch_id == launch_id and state.auth_request) &&
         state.auth_request.request_id == request_id do
      authenticated? =
        auth_completion_valid?(state, socket.assigns.mini_app_user_id, status, params)

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

      not current_compose_grant?(socket, state) ->
        socket = assign_oauth_authenticated(socket, false)
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
      socket = Phoenix.Component.assign(socket, :mini_app_host, %{state | load_error?: true})

      socket =
        if developer_card?(state.card) do
          Phoenix.Component.assign(socket, :mini_app_developer_check, :fail)
        else
          socket
        end

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event("mini_app_frame_retry", _params, socket) do
    state = socket.assigns.mini_app_host

    if state.status == :open and state.load_error? and active_card?(state.card) do
      launch_id = launch_id()

      socket =
        Phoenix.Component.assign(socket, :mini_app_host, %{
          state
          | launch_id: launch_id,
            ready?: false,
            load_error?: false,
            auth_request: nil,
            oauth_authenticated?: false,
            context_request: nil,
            notification_request: nil,
            compose_request: nil,
            external_request: nil,
            wallet_request: nil,
            wallet_incompatible?: false,
            broker_budget: new_broker_budget()
        })

      socket =
        if developer_card?(state.card) do
          Phoenix.Component.assign(socket, :mini_app_developer_check, :pending)
        else
          socket
        end

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
         } = event_params,
         socket
       )
       when method in ["eth_accounts", "eth_chainId", "eth_requestAccounts"] do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    if exact_keys?(event_params, [
         "launch_id",
         "request_id",
         "method",
         "params"
       ]) and wallet_request_allowed?(state, launch_id, request_id, user_id) do
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
         } = event_params,
         socket
       )
       when method in ["personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"] do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    with true <-
           exact_keys?(event_params, ["launch_id", "request_id", "method", "params"]),
         true <- wallet_request_allowed?(state, launch_id, request_id, user_id),
         approved when approved != [] <-
           WalletConnections.accounts(user_id, state.card.app_origin),
         {:ok, request} <- WalletRequest.validate(method, params, approved) do
      pending =
        Map.merge(request, %{launch_id: launch_id, request_id: request_id, confirm?: false})

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
         } = event_params,
         socket
       ) do
    state = socket.assigns.mini_app_host

    case state.wallet_request do
      %{request_id: ^request_id, account: account, confirm?: false} = request
      when state.launch_id == launch_id ->
        with true <-
               exact_keys?(event_params, [
                 "launch_id",
                 "request_id",
                 "status",
                 "chain_id",
                 "accounts"
               ]),
             {:ok, pending} <-
               WalletRequest.bind_review(request, launch_id, request_id, chain_id, accounts),
             true <- account in pending.expected_accounts,
             true <- wallet_chain_allowed?(state, pending.expected_chain_id) do
          {:halt,
           Phoenix.Component.assign(socket, :mini_app_host, %{
             state
             | wallet_request: %{pending | confirm?: true}
           })}
        else
          _other ->
            {:halt,
             push_wallet_error(socket, request_id, 4901, "Wallet account or chain changed")}
        end

      _other ->
        {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_wallet_preflight_result",
         %{"launch_id" => launch_id, "request_id" => request_id, "status" => "error"} =
           event_params,
         socket
       ) do
    state = socket.assigns.mini_app_host

    if (exact_keys?(event_params, ["launch_id", "request_id", "status"]) and
          (state.launch_id == launch_id and state.wallet_request)) &&
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
        with {:ok, request} <-
               WalletRequest.bind_execution(
                 Map.put(request, :params, []),
                 state.launch_id,
                 request_id
               ),
             {:ok, request} <- WalletRequest.issue_execution(request, launch_id()) do
          socket =
            socket
            |> Phoenix.Component.assign(:mini_app_host, %{
              state
              | wallet_request: %{request | confirm?: false}
            })
            |> push_wallet_execute(request)

          {:halt, socket}
        else
          _other ->
            {:halt, push_wallet_error(socket, request_id, 4100, "Wallet access unavailable")}
        end

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
             true <- validated.fingerprint == fingerprint,
             true <- validated.params == params,
             true <- request.launch_id == state.launch_id,
             {:ok, request} <- WalletRequest.issue_execution(request, launch_id()) do
          socket =
            socket
            |> Phoenix.Component.assign(:mini_app_host, %{
              state
              | wallet_request: %{request | confirm?: false}
            })
            |> push_wallet_execute(request,
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
         %{
           "launch_id" => launch_id,
           "request_id" => request_id,
           "execution_token" => execution_token,
           "method" => method,
           "status" => "ok",
           "result" => _result
         } = params,
         socket
       ) do
    state = socket.assigns.mini_app_host

    if exact_keys?(params, [
         "launch_id",
         "request_id",
         "execution_token",
         "method",
         "status",
         "result"
       ]) and
         wallet_execution_matches?(
           state,
           launch_id,
           request_id,
           method,
           execution_token,
           socket.assigns.mini_app_user_id
         ) do
      {:halt, finish_wallet_execution(socket, params)}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_wallet_execution_result",
         %{
           "launch_id" => launch_id,
           "request_id" => request_id,
           "execution_token" => execution_token,
           "method" => method,
           "status" => "error",
           "code" => _code
         } = params,
         socket
       ) do
    state = socket.assigns.mini_app_host

    if exact_keys?(params, [
         "launch_id",
         "request_id",
         "execution_token",
         "method",
         "status",
         "code"
       ]) and
         wallet_execution_matches?(
           state,
           launch_id,
           request_id,
           method,
           execution_token,
           socket.assigns.mini_app_user_id
         ) do
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
      socket =
        Phoenix.Component.assign(socket, :mini_app_host, %{
          state
          | ready?: event == "mini_app_ready",
            load_error?: false,
            auth_request: if(event == "mini_app_loading", do: nil, else: state.auth_request),
            notification_request:
              if(event == "mini_app_loading", do: nil, else: state.notification_request),
            oauth_authenticated?:
              if(event == "mini_app_loading", do: false, else: state.oauth_authenticated?),
            compose_request:
              if(event == "mini_app_loading", do: nil, else: state.compose_request),
            external_request:
              if(event == "mini_app_loading", do: nil, else: state.external_request),
            wallet_request: if(event == "mini_app_loading", do: nil, else: state.wallet_request)
        })

      socket =
        cond do
          not developer_card?(state.card) ->
            socket

          event == "mini_app_ready" ->
            Phoenix.Component.assign(socket, :mini_app_developer_check, :pass)

          event == "mini_app_loading" ->
            Phoenix.Component.assign(socket, :mini_app_developer_check, :pending)
        end

      {:halt, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_host_event(
         "mini_app_protocol_violation",
         %{"launch_id" => launch_id, "reason" => reason},
         socket
       )
       when reason in [
              "ready_required",
              "message_bytes",
              "total_bytes",
              "message_count",
              "request_count",
              "outstanding",
              "rate_limit"
            ] do
    state = socket.assigns.mini_app_host

    if state.status in [:open, :collapsed] and state.launch_id == launch_id do
      {:halt, Phoenix.Component.assign(socket, :mini_app_host, closed_state())}
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

  defp auth_completion_valid?(_state, _user_id, status, _params) when status != "success",
    do: false

  defp auth_completion_valid?(%{auth_request: request} = state, user_id, "success", params) do
    case request.completion_mode do
      "backend_handoff" ->
        not Map.has_key?(params, "authorization_code") and
          OAuthRegistrations.active_user_grant?(state.card.app_origin, user_id)

      "browser_code" ->
        OAuth.pending_browser_authorization_code?(
          Map.get(params, "authorization_code"),
          request.application_id,
          user_id,
          request.redirect_uri,
          Enum.join(request.scopes, " "),
          request.code_challenge
        )
    end
  end

  defp update_status(socket, status) do
    state = socket.assigns.mini_app_host

    if state.card do
      Phoenix.Component.assign(socket, :mini_app_host, %{state | status: status})
    else
      socket
    end
  end

  defp active_card?(%Card{} = card) do
    if developer_card?(card), do: DeveloperLaunches.active?(card), else: Cards.active?(card)
  end

  defp active_card?(_card), do: false

  defp active_card(card_id, resolution_token, current_user) do
    Cards.get_active_by_id(card_id, resolution_token) ||
      DeveloperLaunches.get_active(card_id, resolution_token, current_user)
  end

  defp launch_info(%Card{} = card) do
    if developer_card?(card) do
      case DeveloperLaunches.launch_info(card) do
        %{} = info -> {:ok, info}
        _ -> {:error, :invalid_developer_launch}
      end
    else
      LaunchContext.public_for_card(card)
    end
  end

  defp developer_card?(%Card{developer_user_id: user_id}), do: is_binary(user_id)
  defp developer_card?(_card), do: false

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
      launch_info: nil,
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
      wallet_incompatible?: false,
      broker_budget: nil
    }
  end

  defp new_broker_budget do
    %{
      messages: 0,
      requests: 0,
      total_bytes: 0,
      rate_tokens: @broker_rate_capacity * 1.0,
      rate_updated_at: System.monotonic_time(:millisecond)
    }
  end

  defp launch_info_json(%{launch_info: %{} = launch_info}), do: Jason.encode!(launch_info)
  defp launch_info_json(_state), do: nil

  defp consume_broker_budget(budget, event, params) when is_map(budget) do
    with {:ok, encoded} <- Jason.encode(params),
         message_bytes <- byte_size(encoded),
         true <- message_bytes <= @broker_max_message_bytes or {:error, :message_bytes},
         true <-
           budget.total_bytes + message_bytes <= @broker_max_total_bytes or
             {:error, :total_bytes},
         true <- budget.messages < @broker_max_messages or {:error, :message_count},
         request_count <- budget.requests + if(event in @broker_request_events, do: 1, else: 0),
         true <- request_count <= @broker_max_requests or {:error, :request_count},
         {:ok, rate_tokens, updated_at} <- consume_broker_rate(budget) do
      {:ok,
       %{
         budget
         | messages: budget.messages + 1,
           requests: request_count,
           total_bytes: budget.total_bytes + message_bytes,
           rate_tokens: rate_tokens,
           rate_updated_at: updated_at
       }}
    else
      {:error, _reason} = error -> error
      false -> {:error, :budget}
    end
  end

  defp consume_broker_budget(_budget, _event, _params), do: {:error, :budget}

  defp consume_broker_rate(budget) do
    now = System.monotonic_time(:millisecond)
    elapsed = max(now - budget.rate_updated_at, 0)

    tokens =
      min(
        @broker_rate_capacity * 1.0,
        budget.rate_tokens + elapsed * @broker_rate_per_second / 1_000
      )

    if tokens >= 1.0,
      do: {:ok, tokens - 1.0, now},
      else: {:error, :rate_limit}
  end

  defp host_request_pending?(state) do
    Enum.any?(
      [
        state.context_request,
        state.auth_request,
        state.notification_request,
        state.compose_request,
        state.external_request,
        state.wallet_request
      ],
      &(not is_nil(&1))
    )
  end

  defp reject_concurrent_request(socket, "mini_app_context_request", %{
         "request_id" => request_id
       }) do
    if valid_request_id?(request_id) do
      state = socket.assigns.mini_app_host

      Phoenix.LiveView.push_event(socket, "mini_app_context_response", %{
        launch_id: state.launch_id,
        request_id: request_id,
        status: "unavailable",
        context: nil
      })
    else
      socket
    end
  end

  defp reject_concurrent_request(socket, "mini_app_notification_permission_request", %{
         "request_id" => request_id
       }) do
    if valid_request_id?(request_id) do
      state = socket.assigns.mini_app_host

      Phoenix.LiveView.push_event(socket, "mini_app_notification_permission_response", %{
        launch_id: state.launch_id,
        request_id: request_id,
        status: "unavailable"
      })
    else
      socket
    end
  end

  defp reject_concurrent_request(socket, "mini_app_auth_request", %{
         "request_id" => request_id
       }) do
    if valid_request_id?(request_id) do
      state = socket.assigns.mini_app_host

      Phoenix.LiveView.push_event(socket, "mini_app_auth_response", %{
        launch_id: state.launch_id,
        request_id: request_id,
        status: "error"
      })
    else
      socket
    end
  end

  defp reject_concurrent_request(socket, "mini_app_compose_request", %{"call_id" => call_id}) do
    if valid_request_id?(call_id) do
      state = socket.assigns.mini_app_host

      Phoenix.LiveView.push_event(socket, "mini_app_compose_response", %{
        launch_id: state.launch_id,
        call_id: call_id,
        status: "unavailable"
      })
    else
      socket
    end
  end

  defp reject_concurrent_request(socket, "mini_app_external_request", %{
         "request_id" => request_id
       }) do
    if valid_request_id?(request_id) do
      state = socket.assigns.mini_app_host

      Phoenix.LiveView.push_event(socket, "mini_app_external_response", %{
        launch_id: state.launch_id,
        request_id: request_id,
        status: "denied"
      })
    else
      socket
    end
  end

  defp reject_concurrent_request(socket, "mini_app_wallet_request", %{
         "request_id" => request_id
       }) do
    if valid_request_id?(request_id) do
      push_wallet_rejection(
        socket,
        request_id,
        -32_002,
        "Another mini app request is already pending"
      )
    else
      socket
    end
  end

  defp reject_concurrent_request(socket, _event, _params), do: socket

  defp context_request_allowed?(state, launch_id, request_id) do
    state.status == :open and state.ready? and state.launch_id == launch_id and
      is_nil(state.context_request) and is_nil(state.auth_request) and
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

  defp wallet_execution_matches?(
         state,
         launch_id,
         request_id,
         method,
         execution_token,
         user_id
       ) do
    request = state.wallet_request

    state.status == :open and state.launch_id == launch_id and is_binary(user_id) and
      is_map(request) and request.method == method and
      WalletRequest.execution_matches?(request, launch_id, request_id, execution_token) and
      active_card?(state.card) and Declarations.wallet_enabled?(state.card.app_origin) and
      wallet_execution_account_allowed?(request, user_id, state.card.app_origin)
  end

  defp wallet_execution_account_allowed?(%{account: account}, user_id, app_origin),
    do: account in WalletConnections.accounts(user_id, app_origin)

  defp wallet_execution_account_allowed?(_request, _user_id, _app_origin), do: true

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

  defp exact_keys?(map, keys) when is_map(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

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
    request = %{request_id: request_id, method: method, params: [], confirm?: false}

    with {:ok, request} <-
           WalletRequest.bind_execution(request, state.launch_id, request_id),
         {:ok, request} <- WalletRequest.issue_execution(request, launch_id()) do
      socket
      |> Phoenix.Component.assign(:mini_app_host, %{state | wallet_request: request})
      |> push_wallet_execute(request)
    else
      _other -> push_wallet_rejection(socket, request_id, 4100, "Wallet access unavailable")
    end
  end

  defp push_wallet_execute(socket, request, extra \\ []) do
    state = socket.assigns.mini_app_host

    payload = %{
      launch_id: state.launch_id,
      request_id: request.request_id,
      execution_token: request.execution_token,
      method: request.method,
      params: request.params
    }

    Phoenix.LiveView.push_event(
      socket,
      "mini_app_wallet_execute",
      Map.merge(payload, Map.new(extra))
    )
  end

  defp finish_wallet_execution(socket, %{"status" => "error"} = params) do
    request_id = socket.assigns.mini_app_host.wallet_request.request_id
    code = WalletRequest.normalize_error_code(Map.get(params, "code"))
    push_wallet_error(socket, request_id, code, "Wallet request failed")
  end

  defp finish_wallet_execution(socket, %{"status" => "ok", "result" => result}) do
    state = socket.assigns.mini_app_host
    user_id = socket.assigns.mini_app_user_id

    case state.wallet_request.method do
      "eth_chainId" ->
        push_validated_wallet_result(socket, "eth_chainId", result)

      "eth_requestAccounts" ->
        with {:ok, accounts} <- WalletRequest.validate_result("eth_requestAccounts", result),
             {:ok, connection} <-
               WalletConnections.connect(user_id, state.card.app_origin, accounts) do
          push_wallet_result(socket, state.wallet_request.request_id, connection.accounts)
        else
          _other ->
            push_wallet_error(
              socket,
              state.wallet_request.request_id,
              -32603,
              "Invalid wallet response"
            )
        end

      "eth_accounts" ->
        approved = WalletConnections.accounts(user_id, state.card.app_origin)

        case WalletRequest.validate_result("eth_accounts", result) do
          {:ok, current} ->
            push_wallet_result(
              socket,
              state.wallet_request.request_id,
              Enum.filter(approved, &(&1 in current))
            )

          _error ->
            push_wallet_error(
              socket,
              state.wallet_request.request_id,
              -32603,
              "Invalid wallet response"
            )
        end

      method when method in ["personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"] ->
        push_validated_wallet_result(socket, method, result)
    end
  end

  defp finish_wallet_execution(socket, _params) do
    request_id = socket.assigns.mini_app_host.wallet_request.request_id
    push_wallet_error(socket, request_id, -32603, "Invalid wallet response")
  end

  defp push_validated_wallet_result(socket, method, result) do
    request_id = socket.assigns.mini_app_host.wallet_request.request_id

    case WalletRequest.validate_result(method, result) do
      {:ok, result} ->
        push_wallet_result(socket, request_id, result)

      _error ->
        push_wallet_error(socket, request_id, -32603, "Invalid wallet response")
    end
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

  defp submit_compose(socket, params) do
    state = socket.assigns.mini_app_host

    with %{request_id: request_id} = request <- state.compose_request,
         user_id when is_binary(user_id) <- socket.assigns.mini_app_user_id,
         {:ok, id, scope} <- publish_compose(socket, state, request, params, user_id) do
      socket
      |> Phoenix.Component.assign(:mini_app_host, %{state | compose_request: nil})
      |> Phoenix.LiveView.push_event("mini_app_compose_published", %{
        launch_id: state.launch_id,
        request_id: request_id,
        id: id,
        scope: scope
      })
    else
      {:error, :oauth_grant} ->
        socket
        |> assign_oauth_authenticated(false)
        |> put_compose_error("Authorization expired. Authenticate again before posting.")

      _ ->
        put_compose_error(socket, "Could not post. Review the draft and try again.")
    end
  end

  defp publish_compose(socket, state, request, params, user_id) do
    Repo.transaction(fn ->
      GrantLock.acquire(user_id, state.card.app_origin)

      with {:oauth_grant, true} <- {:oauth_grant, current_compose_grant?(socket, state)},
           true <- active_card?(state.card),
           true <- OAuthRegistrations.capability_allowed?(state.card.app_origin, "compose_note"),
           %User{} = user <- Users.get(user_id),
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
        {:ok, id, publish.scope}
      else
        {:oauth_grant, false} -> {:error, :oauth_grant}
        _error -> {:error, :publish_failed}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :publish_failed}
    end
  end

  defp current_compose_grant?(socket, state) do
    state.oauth_authenticated? and
      OAuthRegistrations.active_user_grant?(
        state.card.app_origin,
        socket.assigns.mini_app_user_id
      )
  end

  defp assign_oauth_authenticated(socket, authenticated?) when is_boolean(authenticated?) do
    state = socket.assigns.mini_app_host

    Phoenix.Component.assign(socket, :mini_app_host, %{
      state
      | oauth_authenticated?: authenticated?
    })
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

  defp broker_path(%{card: %Card{} = card, launch_id: launch_id})
       when is_binary(launch_id) do
    ~p"/mini-apps/broker/#{card.id}?launch_id=#{launch_id}&resolution_token=#{card.resolution_token}"
  end

  defp broker_path(_state), do: nil

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
