defmodule PleromaReduxWeb.RelationshipsLive do
  use PleromaReduxWeb, :live_view

  alias PleromaRedux.Notifications
  alias PleromaRedux.Relationships
  alias PleromaRedux.User
  alias PleromaRedux.Users
  alias PleromaReduxWeb.ViewModels.Actor, as: ActorVM

  @page_size 40

  @impl true
  def mount(%{"nickname" => nickname}, session, socket) do
    current_user =
      case Map.get(session, "user_id") do
        nil -> nil
        id -> Users.get(id)
      end

    profile_user =
      nickname
      |> to_string()
      |> String.trim()
      |> Users.get_by_nickname()

    {title, items} = list_relationships(profile_user, socket.assigns.live_action, current_user)

    {:ok,
     socket
     |> assign(
       current_user: current_user,
       notifications_count: notifications_count(current_user),
       profile_user: profile_user,
       title: title,
       items: items
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <AppShell.app_shell
        id="relationships-shell"
        nav_id="relationships-nav"
        main_id="relationships-main"
        active={:profile}
        current_user={@current_user}
        notifications_count={@notifications_count}
      >
        <%= if @profile_user do %>
          <section class="space-y-4">
            <.card class="px-5 py-4">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <.link
                  navigate={~p"/@#{@profile_user.nickname}"}
                  class="inline-flex items-center gap-2 rounded-full border border-slate-200/80 bg-white/70 px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-slate-700 transition hover:-translate-y-0.5 hover:bg-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-slate-400 dark:border-slate-700/80 dark:bg-slate-950/60 dark:text-slate-200 dark:hover:bg-slate-950"
                >
                  <.icon name="hero-arrow-left" class="size-4" />
                  Profile
                </.link>

                <div class="text-right">
                  <p
                    data-role="relationships-title"
                    class="font-display text-lg text-slate-900 dark:text-slate-100"
                  >
                    {@title}
                  </p>
                  <p class="mt-1 text-xs uppercase tracking-[0.3em] text-slate-500 dark:text-slate-400">
                    @{to_string(@profile_user.nickname)}
                  </p>
                </div>
              </div>
            </.card>

            <div
              data-role="relationships-list"
              class="space-y-3"
            >
              <div
                :if={@items == []}
                class="rounded-3xl border border-slate-200/80 bg-white/70 p-6 text-sm text-slate-600 shadow-sm shadow-slate-200/20 dark:border-slate-700/70 dark:bg-slate-950/50 dark:text-slate-300 dark:shadow-slate-900/30"
              >
                No results yet.
              </div>

              <.card
                :for={actor <- @items}
                class="p-4"
                data_role="relationship-item"
              >
                <.link
                  navigate={actor_profile_path(actor)}
                  class="flex items-center gap-3"
                >
                  <.avatar
                    size="sm"
                    name={actor.display_name}
                    src={actor.avatar_url}
                  />

                  <div class="min-w-0 flex-1">
                    <p class="truncate text-sm font-semibold text-slate-900 dark:text-slate-100">
                      {actor.display_name}
                    </p>
                    <p class="mt-1 truncate text-xs text-slate-500 dark:text-slate-400">
                      {actor.handle}
                    </p>
                  </div>
                </.link>
              </.card>
            </div>
          </section>
        <% else %>
          <section class="space-y-4">
            <.card class="p-6">
              <p class="text-sm text-slate-600 dark:text-slate-300">
                Profile not found.
              </p>
              <div class="mt-4 flex flex-wrap items-center gap-2">
                <.button navigate={~p"/"} size="sm">Go home</.button>
              </div>
            </.card>
          </section>
        <% end %>
      </AppShell.app_shell>
    </Layouts.app>
    """
  end

  defp list_relationships(nil, _live_action, _current_user), do: {"", []}

  defp list_relationships(%User{} = profile_user, :followers, current_user) do
    items =
      profile_user.ap_id
      |> Relationships.list_follows_to()
      |> Enum.sort_by(& &1.updated_at, :desc)
      |> Enum.take(@page_size)
      |> Enum.map(&Users.get_by_ap_id(&1.actor))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&ActorVM.card(&1.ap_id))

    {title_for(:followers, profile_user, current_user), items}
  end

  defp list_relationships(%User{} = profile_user, :following, current_user) do
    items =
      profile_user.ap_id
      |> Relationships.list_follows_by_actor()
      |> Enum.sort_by(& &1.updated_at, :desc)
      |> Enum.take(@page_size)
      |> Enum.map(&Users.get_by_ap_id(&1.object))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&ActorVM.card(&1.ap_id))

    {title_for(:following, profile_user, current_user), items}
  end

  defp list_relationships(_profile_user, _live_action, _current_user), do: {"", []}

  defp title_for(:followers, %User{} = user, %User{} = current_user) do
    if current_user.id == user.id, do: "Your followers", else: "Followers"
  end

  defp title_for(:following, %User{} = user, %User{} = current_user) do
    if current_user.id == user.id, do: "You're following", else: "Following"
  end

  defp title_for(:followers, _user, _current_user), do: "Followers"
  defp title_for(:following, _user, _current_user), do: "Following"
  defp title_for(_action, _user, _current_user), do: ""

  defp actor_profile_path(%{nickname: nickname}) when is_binary(nickname) and nickname != "" do
    ~p"/@#{nickname}"
  end

  defp actor_profile_path(_actor), do: "#"

  defp notifications_count(nil), do: 0

  defp notifications_count(%User{} = user) do
    user
    |> Notifications.list_for_user(limit: 20)
    |> length()
  end
end
