defmodule EgregorosWeb.Components.Shared.AttachmentGrid do
  @moduledoc """
  Shared component for rendering media attachments (images, videos, audio, links).
  Handles sensitive media warnings and grid layouts.
  """
  use EgregorosWeb, :html

  alias EgregorosWeb.Attachments

  attr :id, :string, required: true
  attr :attachments, :list, required: true
  attr :object, :map, required: true

  def attachment_grid(assigns) do
    assigns =
      assigns
      |> assign_new(:sensitive_media, fn -> sensitive_media?(assigns.object) end)
      |> assign_new(:layout, fn -> attachments_layout(assigns.attachments) end)

    ~H"""
    <div :if={@attachments != []}>
      <.sensitive_media_warning
        :if={@sensitive_media}
        id={@id}
      />

      <div
        id={"attachments-#{@id}"}
        data-role="attachments"
        data-layout={@layout}
        class={[
          "mt-4 grid gap-3",
          @layout == "grid" && "sm:grid-cols-2",
          @sensitive_media && "hidden"
        ]}
      >
        <div :if={@sensitive_media} class="col-span-full flex justify-end">
          <button
            type="button"
            data-role="sensitive-media-hide"
            phx-click={
              JS.show(to: "#sensitive-media-#{@id}")
              |> JS.add_class("hidden", to: "#attachments-#{@id}")
            }
            class="inline-flex items-center gap-2 border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] px-3 py-2 text-xs font-bold uppercase text-[color:var(--text-secondary)] transition hover:border-[color:var(--border-default)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal"
          >
            <.icon name="hero-eye-slash" class="size-4" /> Hide media
          </button>
        </div>

        <div
          :for={{attachment, index} <- Enum.with_index(@attachments)}
          class="group overflow-hidden border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)]"
        >
          <.attachment_media
            attachment={attachment}
            post_id={@id}
            index={index}
            layout={@layout}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true

  defp sensitive_media_warning(assigns) do
    ~H"""
    <div
      id={"sensitive-media-#{@id}"}
      data-role="sensitive-media"
      class="mt-4 flex items-center justify-between gap-4 border-2 border-[color:var(--danger)] bg-[color:var(--danger-subtle)] px-4 py-3"
    >
      <div class="flex min-w-0 items-center gap-3">
        <span class="font-mono text-sm font-bold text-[color:var(--danger)]">
          [NSFW]
        </span>

        <div class="min-w-0">
          <p class="font-bold text-[color:var(--text-primary)]">Sensitive media</p>
          <p class="mt-0.5 text-sm text-[color:var(--text-muted)]">Hidden by default.</p>
        </div>
      </div>

      <button
        type="button"
        data-role="sensitive-media-reveal"
        phx-click={
          JS.hide(to: "#sensitive-media-#{@id}")
          |> JS.remove_class("hidden", to: "#attachments-#{@id}")
        }
        class="inline-flex items-center gap-2 border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold uppercase text-[color:var(--bg-base)] transition hover:bg-[color:var(--accent-primary-hover)] focus-visible:outline-none focus-brutal"
      >
        <.icon name="hero-eye" class="size-4" /> Reveal
      </button>
    </div>
    """
  end

  attr :attachment, :map, required: true
  attr :post_id, :any, required: true
  attr :index, :integer, required: true
  attr :layout, :string, default: "grid"

  defp attachment_media(assigns) do
    assigns =
      assign_new(assigns, :height_class, fn ->
        case assigns.layout do
          "single" -> "h-72 sm:h-96"
          _ -> "h-44"
        end
      end)

    ~H"""
    <%= case Attachments.kind(@attachment) do %>
      <% :image -> %>
        <button
          type="button"
          data-role="attachment-open"
          data-index={@index}
          phx-click={JS.dispatch("egregoros:media-open", to: "#media-viewer")}
          class="relative block w-full overflow-hidden text-left focus-visible:outline-none focus-brutal"
          aria-label={attachment_label(@attachment, "Open image")}
        >
          <img
            data-role="attachment"
            data-kind="image"
            src={Map.get(@attachment, :preview_href) || @attachment.href}
            data-full-href={@attachment.href}
            alt={@attachment.description}
            class={[
              @height_class,
              "image-dark-filter w-full object-cover transition duration-300 group-hover:scale-105"
            ]}
            loading="lazy"
          />
          <div class="image-scanlines-overlay pointer-events-none absolute inset-0 z-10"></div>
        </button>
      <% :video -> %>
        <div
          id={"video-player-#{@attachment.href |> :erlang.phash2() |> Integer.to_string()}"}
          phx-hook="VideoPlayer"
          phx-update="ignore"
          class="w-full"
        >
          <video
            data-role="attachment"
            data-kind="video"
            preload="metadata"
            playsinline
            aria-label={attachment_label(@attachment, "Video attachment")}
          >
            <source
              src={@attachment.href}
              type={Attachments.source_type(@attachment, "video/mp4")}
            />
          </video>
        </div>
      <% :audio -> %>
        <div
          id={"audio-player-#{@attachment.href |> :erlang.phash2() |> Integer.to_string()}"}
          phx-hook="AudioPlayer"
          phx-update="ignore"
          class="w-full px-4 py-3"
        >
          <audio
            data-role="attachment"
            data-kind="audio"
            preload="metadata"
            aria-label={attachment_label(@attachment, "Audio attachment")}
            crossorigin="anonymous"
          >
            <source
              src={@attachment.href}
              type={Attachments.source_type(@attachment, "audio/mpeg")}
            />
          </audio>
        </div>
      <% :link -> %>
        <a
          data-role="attachment"
          data-kind="link"
          href={@attachment.href}
          target="_blank"
          rel="nofollow noopener noreferrer"
          class="flex h-44 w-full items-center justify-center gap-3 px-4 font-medium text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-muted)]"
          title={attachment_link_label(@attachment)}
        >
          <.icon name="hero-arrow-down-tray" class="size-5 text-[color:var(--text-muted)]" />
          <span class="truncate">{attachment_link_label(@attachment)}</span>
        </a>
    <% end %>
    """
  end

  def sensitive_media?(%{data: %{} = data}) do
    data
    |> Map.get("sensitive", false)
    |> case do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  def sensitive_media?(_object), do: false

  defp attachments_layout(attachments) when is_list(attachments) do
    if length(attachments) <= 1, do: "single", else: "grid"
  end

  defp attachments_layout(_attachments), do: "grid"

  defp attachment_label(%{description: description}, fallback) when is_binary(description) do
    description = String.trim(description)
    if description == "", do: fallback, else: description
  end

  defp attachment_label(_attachment, fallback), do: fallback

  defp attachment_link_label(%{description: description} = attachment)
       when is_binary(description) do
    description = String.trim(description)
    if description == "", do: attachment_filename(attachment), else: description
  end

  defp attachment_link_label(attachment), do: attachment_filename(attachment)

  defp attachment_filename(%{href: href}) when is_binary(href) and href != "" do
    case URI.parse(href) do
      %URI{path: path} when is_binary(path) and path != "" ->
        path
        |> String.split("/", trim: true)
        |> List.last()
        |> case do
          nil -> href
          value -> value
        end

      _ ->
        href
    end
  end

  defp attachment_filename(_), do: "Attachment"
end
