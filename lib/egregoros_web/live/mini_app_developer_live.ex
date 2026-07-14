defmodule EgregorosWeb.MiniAppDeveloperLive do
  use EgregorosWeb, :live_view

  alias Egregoros.MiniApps.DeveloperLaunches
  alias Egregoros.MiniApps.Diagnostic
  alias Egregoros.MiniApps.Diagnostic.Check
  alias Egregoros.MiniApps.Diagnostic.Report
  alias Egregoros.Notifications
  alias Egregoros.RateLimiter
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.Components.TimelineItems.MiniAppCard
  alias EgregorosWeb.Endpoint

  @impl true
  def mount(_params, session, socket) do
    current_user = session |> Map.get("user_id") |> Users.get()

    case current_user do
      %User{developer_mode: true} = user ->
        {:ok,
         assign(socket,
           current_user: user,
           notifications_count: notifications_count(user),
           page_title: "Miniapp developer",
           probe_form: to_form(%{"url" => ""}, as: :probe),
           report: nil,
           developer_card: nil,
           diagnostic_running?: false,
           host_origin: Endpoint.url()
         )}

      %User{} ->
        {:ok,
         socket
         |> put_flash(:error, "Enable developer tools in Settings first.")
         |> redirect(to: ~p"/settings")}

      nil ->
        {:ok, redirect(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("validate_mini_app", %{"probe" => %{"url" => url}}, socket) do
    cond do
      socket.assigns.diagnostic_running? ->
        {:noreply, socket}

      true ->
        start_diagnostic(socket, url)
    end
  end

  def handle_event("validate_mini_app", _params, socket), do: start_diagnostic(socket, "")

  @impl true
  def handle_async(:mini_app_diagnostic, {:ok, %Report{} = report}, socket) do
    user = Users.get(socket.assigns.current_user.id)

    {card, flash} =
      case {user, report.resolved_card} do
        {%User{developer_mode: true} = user, %{} = resolved_card} ->
          case DeveloperLaunches.put(user, resolved_card) do
            {:ok, card} -> {card, nil}
            {:error, _reason} -> {nil, "The detected card could not be opened safely."}
          end

        _ ->
          {nil, nil}
      end

    socket =
      socket
      |> assign(
        current_user: user || socket.assigns.current_user,
        report: report,
        developer_card: card,
        diagnostic_running?: false
      )
      |> maybe_put_error(flash)

    if match?(%User{developer_mode: true}, user) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Developer tools were disabled while the test was running.")
       |> redirect(to: ~p"/settings")}
    end
  end

  def handle_async(:mini_app_diagnostic, {:exit, _reason}, socket) do
    report = failed_report(socket.assigns.probe_form[:url].value)

    {:noreply,
     assign(socket,
       report: report,
       developer_card: nil,
       diagnostic_running?: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} mini_app_host={@mini_app_host}>
      <AppShell.app_shell
        id="mini-app-developer-shell"
        nav_id="mini-app-developer-nav"
        main_id="mini-app-developer-main"
        active={:developer}
        current_user={@current_user}
        notifications_count={@notifications_count}
      >
        <section class="space-y-6" data-role="mini-app-developer">
          <.card class="p-6">
            <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--accent)]">
              Developer
            </p>
            <h2 class="mt-2 text-2xl font-bold text-[color:var(--text-primary)]">
              Miniapp conformance test
            </h2>
            <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
              Inspect a public HTTPS miniapp URL using Egregoros’s production fetch, parsing,
              image-sanitization, framing, and iframe-message security boundaries.
            </p>

            <.form
              for={@probe_form}
              id="mini-app-diagnostic-form"
              phx-submit="validate_mini_app"
              class="mt-6 space-y-3"
            >
              <.input
                field={@probe_form[:url]}
                type="url"
                label="Exact miniapp URL"
                placeholder="https://miniapp.example/path"
                autocomplete="url"
                required
                disabled={@diagnostic_running?}
              />
              <button
                id="mini-app-diagnostic-submit"
                type="submit"
                disabled={@diagnostic_running?}
                class="inline-flex cursor-pointer items-center gap-2 border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)] transition hover:-translate-y-0.5 hover:shadow-[3px_3px_0_var(--accent)] focus-visible:outline-none focus-brutal disabled:cursor-wait disabled:opacity-60"
              >
                <.icon
                  name={if @diagnostic_running?, do: "hero-arrow-path", else: "hero-beaker"}
                  class={["size-4", @diagnostic_running? && "animate-spin"]}
                />
                {if @diagnostic_running?, do: "Testing…", else: "Test miniapp"}
              </button>
            </.form>

            <div class="mt-5 border-l-4 border-[color:var(--warning)] bg-[color:var(--warning-subtle)] p-4 text-xs leading-relaxed text-[color:var(--text-secondary)]">
              <p class="font-bold text-[color:var(--text-primary)]">Remote, untrusted input</p>
              <p class="mt-1">
                The server makes bounded credential-free GET requests. It never forwards your
                cookies, OAuth tokens, request headers, or identity. Framing checks are evaluated
                for this exact server origin: <span class="font-mono">{@host_origin}</span>.
              </p>
            </div>
          </.card>

          <.card :if={@diagnostic_running?} id="mini-app-diagnostic-running" class="p-6">
            <div class="flex items-center gap-3 text-sm font-bold text-[color:var(--text-primary)]">
              <.icon name="hero-arrow-path" class="size-5 animate-spin" />
              Fetching and validating declared resources…
            </div>
          </.card>

          <.card :if={@report} id="mini-app-diagnostic-results" class="p-6">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--accent)]">
                  Result
                </p>
                <h2 class="mt-2 text-xl font-bold text-[color:var(--text-primary)]">
                  {result_title(@report, ready_status(assigns))}
                </h2>
                <p class="mt-2 text-sm text-[color:var(--text-secondary)]">
                  {result_summary(@report, ready_status(assigns))}
                </p>
              </div>
              <span
                id="mini-app-diagnostic-overall-status"
                data-status={overall_status(@report, ready_status(assigns))}
                class={status_badge_classes(overall_status(@report, ready_status(assigns)))}
              >
                {overall_status_label(@report, ready_status(assigns))}
              </span>
            </div>

            <dl class="mt-5 grid gap-3 text-xs sm:grid-cols-3">
              <div class="border border-[color:var(--border-muted)] p-3">
                <dt class="font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
                  Required
                </dt>
                <dd class="mt-1 text-lg font-bold text-[color:var(--text-primary)]">
                  {check_count(@report, :required, :pass)} / {check_count(
                    @report,
                    :required,
                    :all
                  )}
                </dd>
              </div>
              <div class="border border-[color:var(--border-muted)] p-3">
                <dt class="font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
                  Recommended
                </dt>
                <dd class="mt-1 text-lg font-bold text-[color:var(--text-primary)]">
                  {check_count(@report, :recommended, :pass)} / {check_count(
                    @report,
                    :recommended,
                    :all
                  )}
                </dd>
              </div>
              <div class="border border-[color:var(--border-muted)] p-3">
                <dt class="font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
                  Browser ready()
                </dt>
                <dd class="mt-1 text-lg font-bold text-[color:var(--text-primary)]">
                  {ready_label(ready_status(assigns))}
                </dd>
              </div>
            </dl>
          </.card>

          <.card :if={@developer_card} id="mini-app-diagnostic-preview" class="p-6">
            <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--accent)]">
              Rich-card preview
            </p>
            <h2 class="mt-2 text-lg font-bold text-[color:var(--text-primary)]">
              Open to complete the browser test
            </h2>
            <p class="mt-2 text-sm leading-relaxed text-[color:var(--text-secondary)]">
              This uses the same card, sanitized image proxy, broker iframe, sandbox, origin checks,
              and message protocol as a public-note launch. The app must call
              <code class="font-mono">ready()</code>
              before the host timeout.
            </p>
            <MiniAppCard.mini_app_card
              id="developer-mini-app-card"
              card={@developer_card}
              developer={true}
            />
          </.card>

          <.card :if={@report} id="mini-app-diagnostic-checklist" class="p-6">
            <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--accent)]">
              Checklist
            </p>
            <h2 class="mt-2 text-lg font-bold text-[color:var(--text-primary)]">
              Everything tested
            </h2>
            <p class="mt-2 text-xs leading-relaxed text-[color:var(--text-muted)]">
              Required failures prevent conformance. Recommended failures are hardening guidance.
              When a required prerequisite fails, dependent resources are not requested.
            </p>

            <ul class="mt-5 space-y-3">
              <li
                :for={check <- @report.checks}
                id={"mini-app-diagnostic-check-#{check.id}"}
                data-role="mini-app-diagnostic-check"
                data-status={check.status}
                data-requirement={check.requirement}
                class="border border-[color:var(--border-muted)] p-4"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <p class="font-bold text-[color:var(--text-primary)]">{check.label}</p>
                  <div class="flex items-center gap-2">
                    <span class="font-mono text-[10px] uppercase tracking-wide text-[color:var(--text-muted)]">
                      {check.requirement}
                    </span>
                    <span class={status_badge_classes(check.status)}>
                      {status_label(check.status)}
                    </span>
                  </div>
                </div>
                <p class="mt-2 text-xs leading-relaxed text-[color:var(--text-secondary)]">
                  {check.detail}
                </p>
                <p
                  :if={is_binary(check.url)}
                  class="mt-2 break-all font-mono text-[10px] text-[color:var(--text-muted)]"
                >
                  {check.url}
                </p>
              </li>

              <li
                id="mini-app-diagnostic-check-ready"
                data-role="mini-app-diagnostic-check"
                data-status={ready_status(assigns)}
                data-requirement="required"
                class="border border-[color:var(--border-muted)] p-4"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <p class="font-bold text-[color:var(--text-primary)]">
                    SDK ready() handshake
                  </p>
                  <div class="flex items-center gap-2">
                    <span class="font-mono text-[10px] uppercase tracking-wide text-[color:var(--text-muted)]">
                      required
                    </span>
                    <span class={status_badge_classes(ready_status(assigns))}>
                      {ready_label(ready_status(assigns))}
                    </span>
                  </div>
                </div>
                <p class="mt-2 text-xs leading-relaxed text-[color:var(--text-secondary)]">
                  {ready_detail(ready_status(assigns))}
                </p>
                <p
                  id="mini-app-diagnostic-ready-availability"
                  data-available={to_string(not is_nil(@developer_card))}
                  class="mt-2 border-l-2 border-[color:var(--accent)] pl-3 text-xs leading-relaxed text-[color:var(--text-muted)]"
                >
                  <%= if @developer_card do %>
                    Egregoros produced a safe launch card, so this browser test is available from
                    <strong class="text-[color:var(--text-secondary)]">Open</strong>
                    above. Later header or recommended failures may still leave it runnable, but
                    <code class="font-mono">ready()</code>
                    cannot override any other required failure.
                  <% else %>
                    This browser test cannot run because the server scan did not produce a safe
                    launch card. An early required URL, domain, manifest, or card failure blocks it;
                    fix those checks and test again.
                  <% end %>
                </p>
              </li>
            </ul>
          </.card>
        </section>
      </AppShell.app_shell>
    </Layouts.app>
    """
  end

  defp start_diagnostic(socket, url) do
    user = Users.get(socket.assigns.current_user.id)

    case user do
      %User{developer_mode: true} = user ->
        case RateLimiter.allow?(:mini_app_developer_probe, user.id, 5, 60_000) do
          :ok ->
            url = if is_binary(url), do: String.trim(url), else: ""
            host_origin = socket.assigns.host_origin

            {:noreply,
             socket
             |> assign(
               current_user: user,
               probe_form: to_form(%{"url" => url}, as: :probe),
               report: nil,
               developer_card: nil,
               diagnostic_running?: true
             )
             |> start_async(:mini_app_diagnostic, fn -> Diagnostic.run(url, host_origin) end)}

          {:error, :rate_limited} ->
            {:noreply,
             put_flash(socket, :error, "Too many diagnostic requests. Try again in a minute.")}
        end

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Enable developer tools in Settings first.")
         |> redirect(to: ~p"/settings")}
    end
  end

  defp failed_report(input_url) do
    %Report{
      input_url: input_url,
      checks: [
        %Check{
          id: "diagnostic_internal",
          label: "Diagnostic completed safely",
          status: :fail,
          requirement: :required,
          detail: "The diagnostic worker stopped unexpectedly; no remote bytes were trusted.",
          url: nil
        }
      ]
    }
  end

  defp maybe_put_error(socket, nil), do: socket
  defp maybe_put_error(socket, message), do: put_flash(socket, :error, message)

  defp ready_status(%{developer_card: nil}), do: :fail

  defp ready_status(%{
         developer_card: %{id: card_id},
         mini_app_developer_card_id: card_id,
         mini_app_developer_check: status
       })
       when status in [:pending, :pass, :fail],
       do: status

  defp ready_status(%{developer_card: %{}}), do: :not_run

  defp overall_status(report, ready_status) do
    cond do
      not Report.required_pass?(report) -> :fail
      ready_status == :pass -> :pass
      ready_status == :fail -> :fail
      true -> :pending
    end
  end

  defp result_title(report, ready_status) do
    case overall_status(report, ready_status) do
      :pass -> "Conformant miniapp"
      :fail -> "Miniapp conformance failed"
      :pending -> "Server checks passed"
    end
  end

  defp result_summary(report, ready_status) do
    case overall_status(report, ready_status) do
      :pass ->
        "All required server and browser checks passed."

      :fail ->
        "Review the failed required checks below."

      :pending ->
        "Open the rich card to verify the SDK ready() handshake in a real broker iframe."
    end
  end

  defp overall_status_label(report, ready_status) do
    case overall_status(report, ready_status) do
      :pass -> "Passed"
      :fail -> "Failed"
      :pending -> "Incomplete"
    end
  end

  defp check_count(%Report{checks: checks}, requirement, status) do
    checks
    |> Enum.filter(&(&1.requirement == requirement))
    |> then(fn checks ->
      if status == :all, do: length(checks), else: Enum.count(checks, &(&1.status == status))
    end)
  end

  defp status_label(:pass), do: "Passed"
  defp status_label(:fail), do: "Failed"
  defp status_label(:pending), do: "Waiting"
  defp status_label(:not_run), do: "Not run"

  defp ready_label(status), do: status_label(status)

  defp ready_detail(:pass),
    do: "The framed app called ready() for the current one-time launch ID."

  defp ready_detail(:fail),
    do: "No launchable card was produced, or the framed app did not call ready() before timeout."

  defp ready_detail(:pending), do: "The iframe is open and the host is waiting for ready()."

  defp ready_detail(:not_run),
    do: "Open the rich-card preview above to run this browser-only check."

  defp status_badge_classes(status) do
    [
      "inline-flex border px-2 py-1 text-[10px] font-bold uppercase tracking-wide",
      case status do
        :pass ->
          "border-[color:var(--success)] bg-[color:var(--success-subtle)] text-[color:var(--success)]"

        :fail ->
          "border-[color:var(--danger)] bg-[color:var(--danger-subtle)] text-[color:var(--danger)]"

        _ ->
          "border-[color:var(--warning)] bg-[color:var(--warning-subtle)] text-[color:var(--warning)]"
      end
    ]
  end

  defp notifications_count(%User{} = user) do
    user
    |> Notifications.list_for_user(limit: 20, include_offers?: true)
    |> length()
  end
end
