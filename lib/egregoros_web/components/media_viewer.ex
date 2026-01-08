defmodule EgregorosWeb.MediaViewer do
  use EgregorosWeb, :html

  alias EgregorosWeb.Attachments

  attr :viewer, :map, required: true
  attr :open, :boolean, default: false

  def media_viewer(assigns) do
    items = Map.get(assigns.viewer, :items, [])
    index = Map.get(assigns.viewer, :index, 0)

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:index, index)
      |> assign(:item_count, length(items))

    ~H"""
    <div
      id="media-viewer"
      data-role="media-viewer"
      data-state={if @open, do: "open", else: "closed"}
      data-index={@index}
      data-count={@item_count}
      role="dialog"
      aria-modal="true"
      aria-hidden={if @open, do: "false", else: "true"}
      phx-hook="MediaViewer"
      class={[
        "fixed inset-0 z-50 flex items-center justify-center bg-[color:var(--text-primary)]/80 p-4",
        !@open && "hidden"
      ]}
    >
      <.focus_wrap
        id="media-viewer-dialog"
        phx-click-away={JS.dispatch("egregoros:media-close", to: "#media-viewer")}
        class="relative w-full max-w-4xl overflow-hidden border-2 border-[color:var(--border-default)] bg-black"
      >
        <.icon_button
          data-role="media-viewer-prev"
          phx-click={JS.dispatch("egregoros:media-prev", to: "#media-viewer")}
          label="Previous media"
          variant="overlay"
          class={[
            "absolute left-4 top-1/2 z-20 -translate-y-1/2",
            @item_count < 2 && "hidden"
          ]}
        >
          <.icon name="hero-chevron-left" class="size-5" />
        </.icon_button>

        <.icon_button
          data-role="media-viewer-close"
          phx-click={JS.dispatch("egregoros:media-close", to: "#media-viewer")}
          label="Close media viewer"
          variant="overlay"
          class="absolute right-4 top-4 z-20"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </.icon_button>

        <.icon_button
          data-role="media-viewer-next"
          phx-click={JS.dispatch("egregoros:media-next", to: "#media-viewer")}
          label="Next media"
          variant="overlay"
          class={[
            "absolute right-4 top-1/2 z-20 -translate-y-1/2",
            @item_count < 2 && "hidden"
          ]}
        >
          <.icon name="hero-chevron-right" class="size-5" />
        </.icon_button>

        <div data-role="media-viewer-slides" class="relative">
          <div
            :for={{item, idx} <- Enum.with_index(@items)}
            data-role="media-viewer-slide"
            data-index={idx}
            data-state={if idx == @index, do: "active", else: "inactive"}
            aria-hidden={if idx == @index, do: "false", else: "true"}
            class={[
              "w-full",
              idx != @index && "hidden"
            ]}
          >
            <%= case Attachments.kind(item) do %>
              <% :video -> %>
                <video
                  data-role="media-viewer-item"
                  controls
                  preload="metadata"
                  playsinline
                  class="max-h-[85vh] w-full bg-black"
                  aria-label={Map.get(item, :description, "Video attachment")}
                >
                  <source src={item.href} type={Attachments.source_type(item, "video/mp4")} />
                </video>
              <% :audio -> %>
                <div class="flex max-h-[85vh] w-full items-center justify-center bg-black/90 px-6 py-10">
                  <div
                    id={"media-audio-player-#{item.href |> :erlang.phash2() |> Integer.to_string()}"}
                    phx-hook="AudioPlayer"
                    phx-update="ignore"
                    class="w-full max-w-xl"
                  >
                    <audio
                      data-role="media-viewer-item"
                      preload="metadata"
                      aria-label={Map.get(item, :description, "Audio attachment")}
                    >
                      <source src={item.href} type={Attachments.source_type(item, "audio/mpeg")} />
                    </audio>
                  </div>
                </div>
              <% _ -> %>
                <img
                  data-role="media-viewer-item"
                  src={item.href}
                  alt={Map.get(item, :description, "")}
                  class="max-h-[85vh] w-full object-contain"
                  loading="lazy"
                />
            <% end %>
          </div>
        </div>
      </.focus_wrap>
    </div>
    """
  end
end
