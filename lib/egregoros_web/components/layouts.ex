defmodule EgregorosWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use EgregorosWeb, :html

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
              <a
                href={~p"/settings"}
                class="hidden px-3 py-2 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:text-[color:var(--text-primary)] hover:underline underline-offset-4 sm:block"
              >
                Settings
              </a>
              <.form for={%{}} action={~p"/logout"} method="post" class="hidden sm:block">
                <button
                  type="submit"
                  class="flex items-center gap-2 px-3 py-2 text-sm font-medium uppercase text-[color:var(--text-secondary)] transition hover:text-[color:var(--text-primary)] hover:underline underline-offset-4"
                >
                  <span class="font-mono font-bold text-[color:var(--text-primary)]">
                    {@current_user.nickname}
                  </span>
                  <span class="text-[color:var(--text-muted)]">&middot;</span>
                  <span>Logout</span>
                </button>
              </.form>
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
        class="flex h-8 w-8 items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-base)] hover:text-[color:var(--text-primary)] [[data-theme-mode=system]_&]:bg-[color:var(--text-primary)] [[data-theme-mode=system]_&]:text-[color:var(--bg-base)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="flex h-8 w-8 items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-base)] hover:text-[color:var(--text-primary)] [[data-theme-mode=light]_&]:bg-[color:var(--text-primary)] [[data-theme-mode=light]_&]:text-[color:var(--bg-base)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="flex h-8 w-8 items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-base)] hover:text-[color:var(--text-primary)] [[data-theme-mode=dark]_&]:bg-[color:var(--text-primary)] [[data-theme-mode=dark]_&]:text-[color:var(--bg-base)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
