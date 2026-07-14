defmodule EgregorosWeb.MiniAppDeveloperLive do
  use EgregorosWeb, :live_view

  alias Egregoros.Notifications
  alias Egregoros.User
  alias Egregoros.Users

  @impl true
  def mount(_params, session, socket) do
    current_user = session |> Map.get("user_id") |> Users.get()

    case current_user do
      %User{developer_mode: true} = user ->
        {:ok,
         assign(socket,
           current_user: user,
           notifications_count: notifications_count(user),
           page_title: "Miniapp developer"
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
              Inspect a public HTTPS miniapp URL using Egregoros’s production security boundary.
            </p>
          </.card>
        </section>
      </AppShell.app_shell>
    </Layouts.app>
    """
  end

  defp notifications_count(%User{} = user) do
    user
    |> Notifications.list_for_user(limit: 20, include_offers?: true)
    |> length()
  end
end
