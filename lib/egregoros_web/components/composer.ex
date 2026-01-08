defmodule EgregorosWeb.Composer do
  use EgregorosWeb, :html

  @moduledoc false

  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :upload, :any, required: true
  attr :media_alt, :map, default: %{}
  attr :param_prefix, :string, required: true
  attr :id_prefix, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global

  attr :change_event, :string, required: true
  attr :submit_event, :string, required: true
  attr :cancel_event, :string, required: true
  attr :toggle_cw_event, :string, required: true

  attr :max_chars, :integer, default: 5000
  attr :options_open?, :boolean, default: false
  attr :cw_open?, :boolean, default: false
  attr :error, :string, default: nil
  attr :submit_label, :string, default: "Post"
  attr :mention_suggestions, :list, default: []

  slot :extra_fields

  def composer_form(assigns) do
    assigns =
      assigns
      |> assign_new(:options_state_id, fn -> "#{assigns.id_prefix}-options-state" end)
      |> assign_new(:cw_id, fn -> "#{assigns.id_prefix}-cw" end)
      |> assign_new(:options_id, fn -> "#{assigns.id_prefix}-options" end)
      |> assign_new(:visibility_menu_id, fn -> "#{assigns.id_prefix}-visibility-menu" end)
      |> assign_new(:language_menu_id, fn -> "#{assigns.id_prefix}-language-menu" end)
      |> assign_new(:language_input_id, fn -> "#{assigns.id_prefix}-language-input" end)
      |> assign_new(:emoji_picker_id, fn -> "#{assigns.id_prefix}-emoji-picker" end)
      |> assign_new(:media_input_id, fn -> "#{assigns.id_prefix}-media-input" end)
      |> assign_new(:content_id, fn -> "#{assigns.id_prefix}-content" end)
      |> assign_new(:editor_id, fn -> "#{assigns.id_prefix}-editor" end)
      |> assign_new(:mentions_id, fn -> "#{assigns.id_prefix}-mention-suggestions" end)

    ~H"""
    <.form
      for={@form}
      id={@id}
      phx-hook="ComposeSettings"
      phx-change={@change_event}
      phx-submit={@submit_event}
      class={["space-y-3", @class]}
      {@rest}
    >
      <.input
        type="hidden"
        id={@options_state_id}
        name={"#{@param_prefix}[ui_options_open]"}
        value={Map.get(@form.params || %{}, "ui_options_open", "false")}
        data-role="compose-options-state"
      />

      {render_slot(@extra_fields)}

      <div
        id={@editor_id}
        data-role="compose-editor"
        phx-hook="ComposeMentions"
        data-mention-scope={@id_prefix}
        phx-drop-target={@upload.ref}
        class="overflow-visible border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] transition focus-within:shadow-[4px_4px_0_var(--border-default)]"
      >
        <div class="flex flex-wrap gap-2 overflow-visible px-4 pt-4">
          <div class="relative">
            <button
              type="button"
              data-role="compose-visibility-pill"
              phx-click={toggle_menu_js(@visibility_menu_id)}
              class="inline-flex items-center gap-2 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-xs font-bold uppercase text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              aria-label="Post visibility"
              aria-expanded="false"
            >
              <.icon name="hero-globe-alt" class="size-4" />
              <span data-role="compose-visibility-label">
                {visibility_label(Map.get(@form.params || %{}, "visibility"))}
              </span>
            </button>

            <div
              id={@visibility_menu_id}
              data-role="compose-visibility-menu"
              data-state="closed"
              data-placement="bottom"
              phx-click-away={close_menu_js(@visibility_menu_id)}
              phx-window-keydown={close_menu_js(@visibility_menu_id)}
              phx-key="escape"
              class="absolute left-0 z-40 hidden w-72 border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-4 data-[placement=bottom]:top-full data-[placement=bottom]:mt-2 data-[placement=bottom]:bottom-auto data-[placement=bottom]:mb-0 data-[placement=top]:bottom-full data-[placement=top]:mb-2 data-[placement=top]:top-auto data-[placement=top]:mt-0"
            >
              <p class="text-xs font-bold uppercase tracking-wider text-[color:var(--text-muted)]">
                Visibility
              </p>

              <% current_visibility =
                (@form.params || %{})
                |> Map.get("visibility", "public")
                |> to_string()
                |> String.trim() %>

              <div class="mt-3 space-y-1">
                <.visibility_option
                  :for={option <- visibility_options()}
                  menu_id={@visibility_menu_id}
                  param_prefix={@param_prefix}
                  current={current_visibility}
                  value={option.value}
                  title={option.title}
                  description={option.description}
                  icon={option.icon}
                />
              </div>
            </div>
          </div>

          <div class="relative">
            <button
              type="button"
              data-role="compose-language-pill"
              phx-click={toggle_menu_js(@language_menu_id)}
              class="inline-flex items-center gap-2 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-xs font-bold uppercase text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              aria-label="Post language"
              aria-expanded="false"
            >
              <.icon name="hero-language" class="size-4" />
              <span data-role="compose-language-label">
                {language_label(Map.get(@form.params || %{}, "language"))}
              </span>
            </button>

            <div
              id={@language_menu_id}
              data-role="compose-language-menu"
              data-state="closed"
              data-placement="bottom"
              phx-click-away={close_menu_js(@language_menu_id)}
              phx-window-keydown={close_menu_js(@language_menu_id)}
              phx-key="escape"
              class="absolute left-0 z-40 hidden w-72 border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-4 data-[placement=bottom]:top-full data-[placement=bottom]:mt-2 data-[placement=bottom]:bottom-auto data-[placement=bottom]:mb-0 data-[placement=top]:bottom-full data-[placement=top]:mb-2 data-[placement=top]:top-auto data-[placement=top]:mt-0"
            >
              <p class="text-xs font-bold uppercase tracking-wider text-[color:var(--text-muted)]">
                Language
              </p>

              <p class="mt-2 text-xs text-[color:var(--text-muted)]">
                Optional. Leave blank for automatic detection.
              </p>

              <input
                id={@language_input_id}
                type="text"
                name={"#{@param_prefix}[language]"}
                value={Map.get(@form.params || %{}, "language", "")}
                placeholder="Auto (e.g. en)"
                phx-debounce="blur"
                class="mt-3 w-full border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-sm text-[color:var(--text-primary)] outline-none transition focus:shadow-[4px_4px_0_var(--border-default)]"
              />
            </div>
          </div>
        </div>

        <div
          id={@cw_id}
          data-role="compose-cw"
          data-state={if @cw_open?, do: "open", else: "closed"}
          class={["px-4 pt-3", !@cw_open? && "hidden"]}
        >
          <.input
            type="text"
            field={@form[:spoiler_text]}
            placeholder="Content warning"
            phx-debounce="blur"
            class="w-full border-2 border-[color:var(--warning)] bg-[color:var(--warning-subtle)] px-3 py-2 text-sm text-[color:var(--text-primary)] outline-none transition focus:shadow-[4px_4px_0_var(--warning)]"
          />
        </div>

        <div class="relative px-4 pb-4 pt-3">
          <.input
            type="textarea"
            id={@content_id}
            field={@form[:content]}
            data-role="compose-content"
            data-max-chars={@max_chars}
            phx-hook="ComposeCharCounter"
            placeholder="What's on your mind?"
            rows="6"
            phx-debounce="blur"
            class="min-h-[7rem] w-full resize-none border-0 bg-transparent p-0 text-base leading-6 text-[color:var(--text-primary)] outline-none placeholder:text-[color:var(--text-muted)] focus:ring-0"
          />

          <div
            :if={@mention_suggestions != []}
            id={@mentions_id}
            data-role="compose-mention-suggestions"
            class="absolute left-4 right-4 top-full z-30 mt-2 overflow-hidden border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)]"
          >
            <ul class="max-h-64 divide-y divide-[color:var(--border-muted)] overflow-y-auto">
              <li :for={suggestion <- @mention_suggestions}>
                <button
                  type="button"
                  data-role="mention-suggestion"
                  data-handle={Map.get(suggestion, :handle) || Map.get(suggestion, "handle") || ""}
                  phx-click={
                    JS.dispatch("egregoros:mention-select",
                      to: "##{@content_id}",
                      detail: %{
                        handle: Map.get(suggestion, :handle) || Map.get(suggestion, "handle") || ""
                      }
                    )
                  }
                  class="flex w-full items-center gap-3 px-4 py-3 text-left transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
                >
                  <div class="flex h-9 w-9 shrink-0 items-center justify-center overflow-hidden border border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] text-sm font-bold text-[color:var(--text-secondary)]">
                    <img
                      :if={
                        is_binary(
                          Map.get(suggestion, :avatar_url) || Map.get(suggestion, "avatar_url")
                        ) and
                          (Map.get(suggestion, :avatar_url) || Map.get(suggestion, "avatar_url")) !=
                            ""
                      }
                      src={Map.get(suggestion, :avatar_url) || Map.get(suggestion, "avatar_url")}
                      alt=""
                      class="h-full w-full object-cover"
                      loading="lazy"
                      decoding="async"
                      referrerpolicy="no-referrer"
                    />
                    <span :if={
                      not is_binary(
                        Map.get(suggestion, :avatar_url) || Map.get(suggestion, "avatar_url")
                      ) or
                        (Map.get(suggestion, :avatar_url) || Map.get(suggestion, "avatar_url")) == ""
                    }>
                      {String.first(
                        to_string(
                          Map.get(suggestion, :nickname) || Map.get(suggestion, "nickname") || "?"
                        )
                      )}
                    </span>
                  </div>

                  <div class="min-w-0 flex-1">
                    <p class="truncate text-sm font-bold text-[color:var(--text-primary)]">
                      {emoji_inline(
                        Map.get(suggestion, :display_name) || Map.get(suggestion, "display_name"),
                        Map.get(suggestion, :emojis) || Map.get(suggestion, "emojis") || []
                      )}
                    </p>
                    <p class="truncate font-mono text-xs text-[color:var(--text-muted)]">
                      {to_string(Map.get(suggestion, :handle) || Map.get(suggestion, "handle") || "")}
                    </p>
                  </div>
                </button>
              </li>
            </ul>
          </div>
        </div>

        <div
          id={@options_id}
          data-role="compose-options"
          data-state={if @options_open?, do: "open", else: "closed"}
          class={[
            "border-t border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] px-4 py-4",
            !@options_open? && "hidden"
          ]}
        >
          <div class="grid gap-4">
            <.input
              type="checkbox"
              field={@form[:sensitive]}
              label="Mark media as sensitive"
            />
          </div>
        </div>

        <div
          :if={@upload.entries != [] or upload_errors(@upload) != []}
          data-role="compose-media"
          class="border-t border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] px-4 py-4"
        >
          <div data-role="compose-media-grid" class="grid gap-3 sm:grid-cols-2">
            <div
              :for={entry <- @upload.entries}
              id={"#{@id_prefix}-media-entry-#{entry.ref}"}
              data-role="media-entry"
              class="border border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-3"
            >
              <div class="space-y-3">
                <div class="relative overflow-hidden border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)]">
                  <div class="relative aspect-video w-full bg-[color:var(--bg-base)]">
                    <.upload_entry_preview entry={entry} />
                  </div>

                  <button
                    type="button"
                    phx-click={@cancel_event}
                    phx-value-ref={entry.ref}
                    class="absolute right-2 top-2 inline-flex h-9 w-9 items-center justify-center border border-[color:var(--border-default)] bg-[color:var(--bg-base)] text-[color:var(--text-muted)] shadow-sm transition hover:bg-[color:var(--bg-subtle)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal"
                    aria-label="Remove attachment"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>

                  <div class="absolute inset-x-0 bottom-0 h-1 bg-black/10">
                    <div
                      class="h-full bg-[color:var(--text-primary)] transition-all"
                      style={"width: #{entry.progress}%"}
                    >
                    </div>
                  </div>
                </div>

                <p class="truncate text-sm font-bold text-[color:var(--text-primary)]">
                  {entry.client_name}
                </p>

                <span class="sr-only" data-role="media-progress">{entry.progress}%</span>

                <details
                  :if={upload_entry_kind(entry) in [:video, :audio]}
                  class="border border-[color:var(--border-muted)] bg-[color:var(--bg-base)] px-4 py-3"
                >
                  <summary class="cursor-pointer select-none text-xs font-bold uppercase tracking-[0.2em] text-[color:var(--text-secondary)] list-none [&::-webkit-details-marker]:hidden">
                    Preview
                  </summary>
                  <div class="mt-3">
                    <.upload_entry_player entry={entry} />
                  </div>
                </details>

                <.input
                  type="text"
                  id={"#{@id_prefix}-media-alt-#{entry.ref}"}
                  name={"#{@param_prefix}[media_alt][#{entry.ref}]"}
                  label="Alt text"
                  value={Map.get(@media_alt, entry.ref, "")}
                  placeholder={upload_entry_description_placeholder(entry)}
                  phx-debounce="blur"
                />

                <p
                  :for={err <- upload_errors(@upload, entry)}
                  data-role="upload-error"
                  class="text-sm text-[color:var(--danger)]"
                >
                  {upload_error_text(err)}
                </p>
              </div>
            </div>
          </div>

          <p
            :for={err <- upload_errors(@upload)}
            data-role="upload-error"
            class="mt-3 text-sm text-[color:var(--danger)]"
          >
            {upload_error_text(err)}
          </p>
        </div>

        <div
          data-role="compose-toolbar"
          class="flex flex-wrap items-center justify-between gap-3 border-t border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] px-4 py-3"
        >
          <div class="flex items-center gap-1">
            <label
              data-role="compose-add-media"
              aria-label="Add media"
              class="relative inline-flex h-10 w-10 cursor-pointer items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)] focus-within:outline-none focus-brutal"
            >
              <.icon name="hero-photo" class="size-5" />
              <span class="sr-only">Add media</span>
              <.live_file_input
                upload={@upload}
                id={@media_input_id}
                class="absolute inset-0 h-full w-full cursor-pointer opacity-0"
              />
            </label>

            <button
              type="button"
              data-role="compose-toggle-cw"
              phx-click={toggle_cw_js(@cw_id) |> JS.push(@toggle_cw_event)}
              aria-label="Content warning"
              class={[
                "inline-flex h-10 w-10 items-center justify-center transition focus-visible:outline-none focus-brutal",
                @cw_open? &&
                  "bg-[color:var(--warning-subtle)] text-[color:var(--warning)]",
                !@cw_open? &&
                  "text-[color:var(--text-muted)] hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)]"
              ]}
            >
              <.icon name="hero-exclamation-triangle" class="size-5" />
            </button>

            <button
              type="button"
              data-role="compose-toggle-options"
              phx-click={toggle_options_js(@options_id, @options_state_id)}
              aria-label="Post options"
              class={[
                "inline-flex h-10 w-10 items-center justify-center transition focus-visible:outline-none focus-brutal",
                @options_open? &&
                  "bg-[color:var(--bg-muted)] text-[color:var(--text-primary)]",
                !@options_open? &&
                  "text-[color:var(--text-muted)] hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)]"
              ]}
            >
              <.icon name="hero-adjustments-horizontal" class="size-5" />
            </button>

            <.compose_emoji_picker id={@emoji_picker_id} />
          </div>

          <% remaining = remaining_chars(@form, @max_chars) %>

          <div class="flex items-center gap-3">
            <div class="flex flex-col items-end gap-1 text-right">
              <span
                data-role="compose-char-counter"
                class={[
                  "font-mono tabular-nums text-sm font-bold",
                  remaining < 0 && "text-[color:var(--danger)]",
                  remaining >= 0 && "text-[color:var(--text-muted)]"
                ]}
              >
                {remaining}
              </span>

              <span
                :if={remaining < 0}
                data-role="compose-char-error"
                class="text-xs font-bold text-[color:var(--danger)]"
              >
                Too long by {abs(remaining)} character{if abs(remaining) == 1, do: "", else: "s"}.
              </span>
            </div>

            <.button
              data-role="compose-submit"
              type="submit"
              phx-disable-with="Posting..."
              disabled={submit_disabled?(@form, @upload, @max_chars)}
              size="sm"
              class="normal-case tracking-normal"
            >
              {@submit_label}
            </.button>
          </div>
        </div>
      </div>

      <p :if={@error} data-role="compose-error" class="text-sm text-[color:var(--danger)]">
        {@error}
      </p>
    </.form>
    """
  end

  defp toggle_options_js(options_id, options_state_id) when is_binary(options_id) do
    JS.toggle_class("hidden", to: "##{options_id}")
    |> JS.toggle_attribute({"value", "true", "false"}, to: "##{options_state_id}")
  end

  defp toggle_menu_js(menu_id) when is_binary(menu_id) do
    JS.toggle_class("hidden", to: "##{menu_id}")
    |> JS.toggle_attribute({"data-state", "open", "closed"}, to: "##{menu_id}")
  end

  defp close_menu_js(menu_id) when is_binary(menu_id) do
    JS.add_class("hidden", to: "##{menu_id}")
    |> JS.set_attribute({"data-state", "closed"}, to: "##{menu_id}")
  end

  defp toggle_cw_js(cw_id) when is_binary(cw_id) do
    JS.toggle_class("hidden", to: "##{cw_id}")
  end

  defp remaining_chars(%Phoenix.HTML.Form{} = form, max_chars) when is_integer(max_chars) do
    max_chars - String.length(content_value(form))
  end

  defp remaining_chars(_form, max_chars) when is_integer(max_chars), do: max_chars

  defp submit_disabled?(form, upload, max_chars) do
    over_limit = remaining_chars(form, max_chars) < 0
    content_blank = String.trim(content_value(form)) == ""
    entries = upload_entries(upload)
    no_attachments = entries == []
    attachments_pending = Enum.any?(entries, &(!&1.done?))

    has_errors =
      match?(%Phoenix.LiveView.UploadConfig{}, upload) and
        (upload.errors != [] or Enum.any?(entries, &(!&1.valid?)))

    over_limit or (content_blank and no_attachments) or attachments_pending or has_errors
  end

  defp content_value(%Phoenix.HTML.Form{} = form) do
    (form.params || %{})
    |> Map.get("content", "")
    |> to_string()
  end

  defp content_value(_form), do: ""

  defp upload_entries(%Phoenix.LiveView.UploadConfig{} = upload), do: upload.entries
  defp upload_entries(_upload), do: []

  attr :menu_id, :string, required: true
  attr :param_prefix, :string, required: true
  attr :current, :string, required: true
  attr :value, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :icon, :string, required: true

  def visibility_option(assigns) do
    ~H"""
    <label
      class="flex cursor-pointer items-start gap-3 px-3 py-2 text-sm text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
      phx-click={close_menu_js(@menu_id)}
    >
      <input
        type="radio"
        class="sr-only"
        name={"#{@param_prefix}[visibility]"}
        value={@value}
        checked={@current == @value}
      />
      <span class="mt-1 inline-flex h-8 w-8 items-center justify-center border border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] text-[color:var(--text-secondary)]">
        <.icon name={@icon} class="size-5" />
      </span>
      <span class="min-w-0">
        <span class="block font-bold text-[color:var(--text-primary)]">{@title}</span>
        <span class="block text-xs text-[color:var(--text-muted)]">
          {@description}
        </span>
      </span>
    </label>
    """
  end

  defp visibility_options do
    [
      %{
        value: "public",
        title: "Public",
        description: "Anyone can see this post.",
        icon: "hero-globe-alt"
      },
      %{
        value: "unlisted",
        title: "Unlisted",
        description: "Not shown on public timelines.",
        icon: "hero-link"
      },
      %{
        value: "private",
        title: "Followers",
        description: "Only your followers can see this.",
        icon: "hero-lock-closed"
      },
      %{
        value: "direct",
        title: "Direct",
        description: "Only mentioned recipients.",
        icon: "hero-envelope"
      }
    ]
  end

  defp visibility_label(visibility) when is_binary(visibility) do
    case String.trim(visibility) do
      "public" -> "Public"
      "unlisted" -> "Unlisted"
      "private" -> "Followers"
      "direct" -> "Direct"
      _ -> "Public"
    end
  end

  defp visibility_label(_visibility), do: "Public"

  defp language_label(language) when is_binary(language) do
    case String.trim(language) do
      "" -> "Auto"
      "auto" -> "Auto"
      value -> value
    end
  end

  defp language_label(_language), do: "Auto"

  defp upload_error_text(:too_large), do: "File is too large."
  defp upload_error_text(:not_accepted), do: "Unsupported file type."
  defp upload_error_text(:too_many_files), do: "Too many files selected."
  defp upload_error_text(_), do: "Upload failed."
end
