defmodule EgregorosWeb.Components.TimelineItems.MiniAppCard do
  @moduledoc false

  use EgregorosWeb, :html

  attr :id, :string, required: true
  attr :card, :map, required: true

  def mini_app_card(assigns) do
    ~H"""
    <section
      id={@id}
      data-role="mini-app-card"
      class="mt-4 overflow-hidden border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] shadow-[4px_4px_0_var(--border-default)]"
    >
      <div class="flex min-w-0 items-stretch">
        <div class="relative flex w-24 shrink-0 items-center justify-center overflow-hidden border-r-2 border-[color:var(--border-default)] bg-[color:var(--accent-subtle)] sm:w-32">
          <img
            :if={is_binary(@card.image_url)}
            src={~p"/mini-app-assets/#{@card.id}/image"}
            alt=""
            loading="lazy"
            decoding="async"
            class="absolute inset-0 h-full w-full object-cover"
          />
          <.icon
            :if={!is_binary(@card.image_url)}
            name="hero-window"
            class="size-9 text-[color:var(--accent)]"
          />
        </div>

        <div class="min-w-0 flex-1 p-4">
          <div class="flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-[color:var(--text-muted)]">
            <span class="inline-block size-2 bg-[color:var(--success)]"></span>
            <span class="truncate">{@card.app_name}</span>
            <span aria-hidden="true">·</span>
            <span class="truncate font-mono normal-case tracking-normal">
              {display_origin(@card.app_origin)}
            </span>
          </div>

          <h3 class="mt-2 truncate text-base font-bold text-[color:var(--text-primary)]">
            {@card.title}
          </h3>

          <button
            id={@id <> "-open"}
            type="button"
            data-role="open-mini-app"
            data-mini-app-card-id={@card.id}
            data-mini-app-origin={@card.app_origin}
            data-mini-app-source-url={@card.source_url}
            data-mini-app-launch-url={@card.launch_url}
            phx-click={
              JS.dispatch("egregoros:mini-app-open",
                detail: %{
                  cardId: @card.id,
                  appOrigin: @card.app_origin,
                  sourceUrl: @card.source_url,
                  launchUrl: @card.launch_url
                }
              )
              |> JS.push("mini_app_open", value: %{"card_id" => @card.id})
            }
            class="mt-3 inline-flex cursor-pointer items-center gap-2 border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold text-[color:var(--bg-base)] transition hover:-translate-y-0.5 hover:shadow-[3px_3px_0_var(--accent)] focus-visible:outline-none focus-brutal"
          >
            <span>{@card.button_title}</span>
            <.icon name="hero-arrow-up-right" class="size-4" />
          </button>
        </div>
      </div>
    </section>
    """
  end

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

  defp display_origin(_origin), do: ""
end
