defmodule EgregorosWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use EgregorosWeb, :html

  alias EgregorosWeb.URL

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :any,
    default: nil,
    doc: "the currently signed-in user (optional)"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-[color:var(--bg-base)] text-[color:var(--text-primary)]">
      <div class="mx-auto max-w-[90rem] px-4 py-8 sm:px-6 lg:px-8">
        <header class="flex flex-col gap-6 border-b-2 border-[color:var(--border-default)] pb-6 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <div class="flex items-center gap-3">
              <div class="flex h-10 w-10 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)]">
                <.icon name="hero-signal" class="size-5 text-[color:var(--bg-base)]" />
              </div>
              <div>
                <h1 class="text-xl font-bold tracking-tight text-[color:var(--text-primary)]">
                  Egregoros
                </h1>
                <p class="font-mono text-sm font-medium text-[color:var(--text-muted)]">
                  Signal feed
                </p>
              </div>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <a
              href="https://docs.joinmastodon.org/client/intro/"
              target="_blank"
              rel="noopener"
              class="px-3 py-2 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:text-[color:var(--text-primary)] hover:underline underline-offset-4"
            >
              API Docs
            </a>

            <%= if @current_user do %>
              <.popover
                id="user-menu"
                data-role="user-menu"
                summary_class="flex cursor-pointer items-center gap-2 px-3 py-2 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:text-[color:var(--text-primary)] hover:underline underline-offset-4 focus-visible:outline-none focus-brutal"
                panel_class="absolute right-0 top-full z-50 mt-2 w-60 overflow-hidden"
              >
                <:trigger>
                  <.avatar
                    size="xs"
                    name={user_display_name(@current_user)}
                    src={user_avatar_src(@current_user)}
                    class="transition group-hover:scale-105"
                  />
                  <span class="hidden font-mono font-bold text-[color:var(--text-primary)] sm:inline">
                    {user_nickname(@current_user)}
                  </span>
                  <.icon
                    name="hero-chevron-down-micro"
                    class="size-4 text-[color:var(--text-muted)] transition group-open:rotate-180"
                  />
                </:trigger>

                <div class="border-b-2 border-[color:var(--border-muted)] px-4 py-3">
                  <p class="truncate font-bold text-[color:var(--text-primary)]">
                    {user_display_name(@current_user)}
                  </p>
                  <p class="truncate font-mono text-sm text-[color:var(--text-muted)]">
                    @{user_nickname(@current_user)}
                  </p>
                </div>

                <nav class="py-1" aria-label="User menu">
                  <a
                    data-role="user-menu-profile"
                    href={~p"/@#{user_nickname(@current_user)}"}
                    class="flex items-center gap-3 px-4 py-2.5 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)] focus-visible:bg-[color:var(--bg-muted)] focus-visible:outline-none"
                  >
                    <.icon name="hero-user-circle" class="size-4" /> Profile
                  </a>

                  <a
                    data-role="user-menu-settings"
                    href={~p"/settings"}
                    class="flex items-center gap-3 px-4 py-2.5 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)] focus-visible:bg-[color:var(--bg-muted)] focus-visible:outline-none"
                  >
                    <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
                  </a>

                  <a
                    data-role="user-menu-privacy"
                    href={~p"/settings/privacy"}
                    class="flex items-center gap-3 px-4 py-2.5 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)] focus-visible:bg-[color:var(--bg-muted)] focus-visible:outline-none"
                  >
                    <.icon name="hero-shield-check" class="size-4" /> Privacy
                  </a>

                  <a
                    data-role="user-menu-notifications"
                    href={~p"/notifications"}
                    class="flex items-center gap-3 px-4 py-2.5 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)] focus-visible:bg-[color:var(--bg-muted)] focus-visible:outline-none"
                  >
                    <.icon name="hero-bell" class="size-4" /> Notifications
                  </a>

                  <%= if Map.get(@current_user, :admin) == true do %>
                    <a
                      data-role="user-menu-admin"
                      href={~p"/admin"}
                      class="flex items-center gap-3 px-4 py-2.5 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)] focus-visible:bg-[color:var(--bg-muted)] focus-visible:outline-none"
                    >
                      <.icon name="hero-shield-check" class="size-4" /> Admin
                    </a>
                  <% end %>
                </nav>

                <div class="border-t-2 border-[color:var(--border-muted)] p-1">
                  <.form for={%{}} action={~p"/logout"} method="post" class="contents">
                    <button
                      type="submit"
                      data-role="user-menu-logout"
                      class="flex w-full cursor-pointer items-center gap-3 px-3 py-2.5 text-left text-sm font-medium uppercase text-[color:var(--danger)] transition hover:bg-[color:var(--bg-muted)] focus-visible:bg-[color:var(--bg-muted)] focus-visible:outline-none"
                    >
                      <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Logout
                    </button>
                  </.form>
                </div>
              </.popover>
            <% else %>
              <a
                href={~p"/login"}
                class="hidden px-3 py-2 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:text-[color:var(--text-primary)] hover:underline underline-offset-4 sm:block"
              >
                Login
              </a>
              <a
                href={~p"/register"}
                class="hidden border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold uppercase text-[color:var(--bg-base)] transition hover:bg-[color:var(--accent-primary-hover)] sm:block"
              >
                Register
              </a>
            <% end %>

            <div class="ml-2 h-6 w-px bg-[color:var(--border-muted)]"></div>
            <.theme_toggle />
          </div>
        </header>

        <main class="mt-8">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed inset-x-0 top-0 z-50 flex flex-col items-end gap-3 px-4 pt-4 sm:inset-auto sm:top-6 sm:right-6 sm:px-0 sm:pt-0"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="flex items-center gap-0 border border-[color:var(--border-default)] bg-[color:var(--bg-subtle)]">
      <button
        type="button"
        class="flex h-8 w-8 cursor-pointer items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-base)] hover:text-[color:var(--text-primary)] [[data-theme-mode=system]_&]:bg-[color:var(--text-primary)] [[data-theme-mode=system]_&]:text-[color:var(--bg-base)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="flex h-8 w-8 cursor-pointer items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-base)] hover:text-[color:var(--text-primary)] [[data-theme-mode=light]_&]:bg-[color:var(--text-primary)] [[data-theme-mode=light]_&]:text-[color:var(--bg-base)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="flex h-8 w-8 cursor-pointer items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-base)] hover:text-[color:var(--text-primary)] [[data-theme-mode=dark]_&]:bg-[color:var(--text-primary)] [[data-theme-mode=dark]_&]:text-[color:var(--bg-base)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end

  defp user_avatar_src(user) when is_map(user) do
    user
    |> Map.get(:avatar_url)
    |> URL.absolute()
  end

  defp user_avatar_src(_user), do: nil

  defp user_display_name(user) when is_map(user) do
    Map.get(user, :name) || Map.get(user, :nickname) || "Unknown"
  end

  defp user_display_name(_user), do: "Unknown"

  defp user_nickname(user) when is_map(user) do
    Map.get(user, :nickname) || "unknown"
  end

  defp user_nickname(_user), do: "unknown"
end
