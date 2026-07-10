defmodule EgregorosWeb.MiniAppHost do
  @moduledoc false

  use EgregorosWeb, :html

  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.AuthRequest
  alias Egregoros.MiniApps.Cards
  alias Egregoros.MiniApps.ComposeDraft
  alias Egregoros.MiniApps.ContextConsents
  alias Egregoros.MiniApps.LaunchContext
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.Publish
  alias Egregoros.User
  alias Egregoros.Users

  def on_mount(:default, _params, session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign(:mini_app_host, closed_state())
      |> Phoenix.Component.assign(:mini_app_user_id, Map.get(session, "user_id"))
      |> Phoenix.LiveView.attach_hook(
        :mini_app_host_events,
        :handle_event,
        &handle_host_event/3
      )

    {:cont, socket}
  end

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

        <div
          :if={@state.status == :open}
          class="relative min-h-0 flex-1 bg-white"
          data-role="mini-app-frame-container"
        >
          <div
            :if={!@state.ready?}
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

          <iframe
            id="mini-app-frame"
            title={@state.card.app_name <> " mini app"}
            src={@state.card.launch_url}
            sandbox="allow-scripts allow-forms allow-same-origin"
            referrerpolicy="no-referrer"
            allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'"
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
        {:halt,
         Phoenix.Component.assign(socket, :mini_app_host, %{
           status: :open,
           expanded?: false,
           card: card,
           launch_id: launch_id(),
           ready?: false,
           context_request: nil,
           auth_request: nil,
           oauth_authenticated?: false,
           compose_request: nil
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

  defp handle_host_event(event, %{"launch_id" => launch_id}, socket)
       when event in ["mini_app_loading", "mini_app_ready"] do
    state = socket.assigns.mini_app_host

    if state.status == :open and state.launch_id == launch_id and active_card?(state.card) do
      {:halt,
       Phoenix.Component.assign(socket, :mini_app_host, %{
         state
         | ready?: event == "mini_app_ready",
           auth_request: if(event == "mini_app_loading", do: nil, else: state.auth_request),
           oauth_authenticated?:
             if(event == "mini_app_loading", do: false, else: state.oauth_authenticated?),
           compose_request: if(event == "mini_app_loading", do: nil, else: state.compose_request)
       })}
    else
      {:halt, socket}
    end
  end

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
    16
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
      context_request: nil,
      auth_request: nil,
      oauth_authenticated?: false,
      compose_request: nil
    }
  end

  defp context_request_allowed?(state, launch_id, request_id) do
    state.status == :open and state.ready? and state.launch_id == launch_id and
      is_nil(state.compose_request) and valid_request_id?(request_id) and active_card?(state.card)
  end

  defp auth_request_allowed?(state, launch_id, request_id) do
    state.status == :open and state.ready? and state.launch_id == launch_id and
      is_nil(state.auth_request) and is_nil(state.context_request) and
      is_nil(state.compose_request) and
      valid_request_id?(request_id) and active_card?(state.card)
  end

  defp compose_request_base_allowed?(state, launch_id, call_id) do
    state.status == :open and state.ready? and state.launch_id == launch_id and
      is_nil(state.auth_request) and is_nil(state.context_request) and
      is_nil(state.compose_request) and valid_request_id?(call_id) and active_card?(state.card)
  end

  defp valid_request_id?(request_id) when is_binary(request_id) do
    byte_size(request_id) <= 64 and String.match?(request_id, ~r/^[A-Za-z0-9_-]+$/)
  end

  defp valid_request_id?(_request_id), do: false

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
    "fixed inset-x-4 bottom-4 z-[60] flex border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] shadow-[6px_6px_0_var(--border-default)] md:left-auto md:w-80"
  end

  defp host_classes(%{status: :open, expanded?: true}) do
    "fixed inset-0 z-[60] flex flex-col border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] shadow-[8px_8px_0_var(--border-default)] md:inset-6"
  end

  defp host_classes(%{status: :open}) do
    "fixed inset-0 z-[60] flex flex-col border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] shadow-[8px_8px_0_var(--border-default)] md:inset-auto md:bottom-6 md:right-6 md:h-[min(695px,calc(100vh-3rem))] md:w-[min(424px,calc(100vw-3rem))]"
  end

  defp card_value(%{card: %Card{} = card}, field), do: Map.get(card, field)
  defp card_value(_state, _field), do: nil

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
