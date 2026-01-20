defmodule EgregorosWeb.Components.Shared.ContentBody do
  @moduledoc """
  Shared component for rendering post/message content with:
  - Content warning (spoiler) handling
  - Collapsible long content
  - E2EE message support
  - HTML sanitization and emoji rendering
  """
  use EgregorosWeb, :html

  alias Egregoros.CustomEmojis
  alias Egregoros.HTML

  @content_collapse_threshold 500

  attr :id, :string, required: true
  attr :object, :map, required: true
  attr :current_user, :any, default: nil
  attr :collapsible, :boolean, default: true

  def content_body(assigns) do
    assigns =
      assigns
      |> assign_new(:collapsible_content, fn ->
        assigns.collapsible and long_content?(assigns.object)
      end)
      |> assign_new(:e2ee_payload, fn -> e2ee_payload_json(assigns.object) end)
      |> assign_new(:current_user_ap_id, fn -> current_user_ap_id(assigns.current_user) end)

    content_id = "post-content-#{assigns.id}"
    fade_id = "#{content_id}-fade"
    toggle_more_id = "#{content_id}-more"
    toggle_less_id = "#{content_id}-less"
    toggle_icon_id = "#{content_id}-icon"

    assigns =
      assigns
      |> assign(:content_id, content_id)
      |> assign(:fade_id, fade_id)
      |> assign(:toggle_more_id, toggle_more_id)
      |> assign(:toggle_less_id, toggle_less_id)
      |> assign(:toggle_icon_id, toggle_icon_id)

    ~H"""
    <div
      id={@content_id}
      data-role="post-content"
      data-e2ee-dm={@e2ee_payload}
      data-current-user-ap-id={@current_user_ap_id}
      phx-hook={if is_binary(@e2ee_payload), do: "E2EEDMMessage", else: nil}
      class={[
        "mt-4 break-words text-base leading-relaxed text-[color:var(--text-secondary)] [&_a]:font-medium [&_a]:text-[color:var(--link)] [&_a]:underline [&_a]:underline-offset-2 [&_a:hover]:text-[color:var(--text-primary)]",
        is_binary(@e2ee_payload) && "whitespace-pre-wrap",
        @collapsible_content && "relative max-h-64 overflow-hidden"
      ]}
    >
      <%= if is_binary(@e2ee_payload) do %>
        <div data-role="e2ee-dm-body">{post_content_html(@object)}</div>
      <% else %>
        {post_content_html(@object)}
      <% end %>

      <div
        :if={is_binary(@e2ee_payload)}
        data-role="e2ee-dm-actions"
        class="mt-3 flex items-center gap-2 text-xs font-bold text-[color:var(--text-muted)]"
      >
        <button
          type="button"
          data-role="e2ee-dm-unlock"
          class="inline-flex cursor-pointer items-center gap-2 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--text-primary)] transition hover:bg-[color:var(--text-primary)] hover:text-[color:var(--bg-base)] focus-visible:outline-none focus-brutal"
        >
          <.icon name="hero-lock-open" class="size-4" /> Unlock
        </button>
      </div>

      <div
        :if={@collapsible_content}
        id={@fade_id}
        class="pointer-events-none absolute inset-x-0 bottom-0 h-20 bg-gradient-to-t from-[color:var(--bg-base)] to-transparent"
        aria-hidden="true"
      >
      </div>
    </div>

    <button
      :if={@collapsible_content}
      type="button"
      data-role="post-content-toggle"
      aria-controls={@content_id}
      aria-expanded="false"
      phx-click={
        JS.toggle_class("max-h-64 overflow-hidden", to: "##{@content_id}")
        |> JS.toggle_class("hidden", to: "##{@fade_id}")
        |> JS.toggle_class("hidden", to: "##{@toggle_more_id}")
        |> JS.toggle_class("hidden", to: "##{@toggle_less_id}")
        |> JS.toggle_class("rotate-180", to: "##{@toggle_icon_id}")
        |> JS.toggle_attribute({"aria-expanded", "true", "false"})
      }
      class="mt-3 inline-flex cursor-pointer items-center gap-2 border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--text-secondary)] transition hover:border-[color:var(--border-default)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal"
    >
      <span id={@toggle_more_id}>Show more</span>
      <span id={@toggle_less_id} class="hidden">Show less</span>
      <span id={@toggle_icon_id} class="inline-flex">
        <.icon name="hero-chevron-down" class="size-4 transition" />
      </span>
    </button>
    """
  end

  attr :object, :map, required: true

  def content_warning(assigns) do
    assigns =
      assign_new(assigns, :content_warning_text, fn ->
        content_warning_text(assigns.object)
      end)

    ~H"""
    <div
      :if={is_binary(@content_warning_text)}
      data-role="content-warning"
      class="flex cursor-pointer items-center justify-between gap-4 border-2 border-[color:var(--warning)] bg-[color:var(--warning-subtle)] px-4 py-3 text-left transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal list-none [&::-webkit-details-marker]:hidden"
    >
      <div class="flex min-w-0 items-start gap-3">
        <span class="mt-0.5 font-mono text-sm font-bold text-[color:var(--warning)]">
          [CW]
        </span>

        <div class="min-w-0">
          <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--warning)]">
            Content warning
          </p>
          <p
            data-role="content-warning-text"
            class="mt-1 truncate font-medium text-[color:var(--text-primary)]"
            title={@content_warning_text}
          >
            {@content_warning_text}
          </p>
        </div>
      </div>

      <span class="inline-flex shrink-0 items-center gap-2 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--text-primary)]">
        <span class="group-open:hidden">Show</span>
        <span class="hidden group-open:inline">Hide</span>
        <.icon name="hero-chevron-down" class="size-4 transition group-open:rotate-180" />
      </span>
    </div>
    """
  end

  def has_content_warning?(object), do: is_binary(content_warning_text(object))

  def content_warning_text(%{data: %{} = data}) do
    case Map.get(data, "summary") do
      summary when is_binary(summary) ->
        summary = String.trim(summary)
        if summary == "", do: nil, else: summary

      _ ->
        nil
    end
  end

  def content_warning_text(_object), do: nil

  defp long_content?(%{data: %{} = data} = object) do
    raw =
      data
      |> Map.get("content", "")
      |> to_string()
      |> String.trim()

    text =
      cond do
        raw == "" ->
          ""

        Map.get(object, :local) ->
          raw

        looks_like_html?(raw) ->
          case FastSanitize.strip_tags(raw) do
            {:ok, stripped} -> stripped
            _ -> raw
          end

        true ->
          raw
      end

    String.length(String.trim(text)) > @content_collapse_threshold
  end

  defp long_content?(_object), do: false

  defp looks_like_html?(content) when is_binary(content) do
    String.contains?(content, "<") and String.contains?(content, ">")
  end

  defp looks_like_html?(_content), do: false

  defp post_content_html(%{data: %{} = data} = object) do
    raw = Map.get(data, "content", "")
    emojis = CustomEmojis.from_object(object)
    ap_tags = Map.get(data, "tag", [])

    raw
    |> HTML.to_safe_html(format: :html, emojis: emojis, ap_tags: ap_tags)
    |> Phoenix.HTML.raw()
  end

  defp post_content_html(_object), do: ""

  defp e2ee_payload_json(%{data: %{} = data}) do
    case Map.get(data, "egregoros:e2ee_dm") do
      %{} = payload when map_size(payload) > 0 -> Jason.encode!(payload)
      _ -> nil
    end
  end

  defp e2ee_payload_json(_object), do: nil

  defp current_user_ap_id(%{ap_id: ap_id}) when is_binary(ap_id), do: ap_id
  defp current_user_ap_id(_current_user), do: ""
end
