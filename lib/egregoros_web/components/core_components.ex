defmodule EgregorosWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework.
  The components in this module form a small, app-specific design system so
  templates can stay consistent without repeating large class lists.

  """
  use Phoenix.Component
  use Gettext, backend: EgregorosWeb.Gettext

  alias Egregoros.HTML
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :class, :any, default: nil, doc: "additional classes for the flash container"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      data-role="toast"
      class={[
        "pointer-events-auto w-full max-w-sm motion-safe:animate-rise overflow-hidden border-2 px-4 py-3",
        "border-[color:var(--border-default)] bg-[color:var(--bg-base)] text-[color:var(--text-primary)]",
        @kind == :error && "border-[color:var(--danger)]",
        @class
      ]}
      {@rest}
    >
      <div class="flex items-start gap-3">
        <div class="mt-0.5 shrink-0 font-mono text-xs font-bold uppercase">
          <span :if={@kind == :info}>[INFO]</span>
          <span :if={@kind == :error} class="text-[color:var(--danger)]">[ERROR]</span>
        </div>

        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-bold leading-6 uppercase text-sm">{@title}</p>
          <p class="text-sm leading-6 text-[color:var(--text-secondary)]">{msg}</p>
        </div>

        <button
          type="button"
          class="group -m-1 inline-flex items-center justify-center p-1 text-[color:var(--text-muted)] transition hover:text-[color:var(--text-primary)] hover:underline focus-visible:outline-none"
          aria-label={gettext("close")}
        >
          <span class="font-mono text-xs">[X]</span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global,
    include:
      ~w(href navigate patch method download disabled phx-click phx-disable-with phx-target)

  attr :class, :any, default: nil
  attr :type, :string, default: nil
  attr :variant, :string, values: ~w(primary secondary ghost destructive), default: "primary"
  attr :size, :string, values: ~w(sm md lg), default: "md"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    link? = rest[:href] || rest[:navigate] || rest[:patch]

    base_classes = [
      "inline-flex cursor-pointer items-center justify-center gap-2 whitespace-nowrap font-semibold uppercase tracking-wide transition-all",
      "focus-visible:outline-none focus-visible:-translate-x-0.5 focus-visible:-translate-y-0.5 focus-visible:shadow-[4px_4px_0_var(--border-default)]",
      "disabled:pointer-events-none disabled:opacity-50"
    ]

    size_classes =
      case assigns.size do
        "sm" -> "px-3 py-1.5 text-xs"
        "lg" -> "px-6 py-3 text-base"
        _ -> "px-4 py-2 text-sm"
      end

    variant_classes =
      case assigns.variant do
        "secondary" ->
          "border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] text-[color:var(--text-primary)] hover:bg-[color:var(--bg-muted)]"

        "ghost" ->
          "bg-transparent text-[color:var(--text-secondary)] hover:text-[color:var(--text-primary)] hover:underline underline-offset-4"

        "destructive" ->
          "border-2 border-[color:var(--danger)] bg-[color:var(--danger)] text-white hover:bg-[color:var(--bg-base)] hover:text-[color:var(--danger)]"

        _ ->
          "border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] text-[color:var(--bg-base)] hover:-translate-x-0.5 hover:-translate-y-0.5 hover:shadow-[4px_4px_0_var(--border-default)]"
      end

    assigns =
      assigns
      |> assign(:button_type, if(link?, do: nil, else: assigns.type || "button"))
      |> assign(:button_class, [base_classes, size_classes, variant_classes, assigns.class])

    if link? do
      ~H"""
      <.link class={@button_class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button type={@button_type} class={@button_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an icon-only button with consistent sizing and focus styles.

  Use `label` to provide an accessible name (`aria-label`) for icon buttons.
  """
  attr :rest, :global,
    include:
      ~w(href navigate patch method download disabled phx-click phx-disable-with phx-target data-role)

  attr :label, :string, required: true
  attr :class, :any, default: nil
  attr :type, :string, default: nil
  attr :variant, :string, values: ~w(surface overlay), default: "surface"
  attr :size, :string, values: ~w(sm md lg), default: "md"

  slot :inner_block, required: true

  def icon_button(%{rest: rest} = assigns) do
    link? = rest[:href] || rest[:navigate] || rest[:patch]

    base_classes = [
      "inline-flex cursor-pointer items-center justify-center transition",
      "focus-visible:outline-none focus-visible:-translate-x-0.5 focus-visible:-translate-y-0.5 focus-visible:shadow-[4px_4px_0_var(--border-default)]",
      "disabled:pointer-events-none disabled:opacity-50"
    ]

    size_classes =
      case assigns.size do
        "sm" -> "h-8 w-8"
        "lg" -> "h-12 w-12"
        _ -> "h-10 w-10"
      end

    variant_classes =
      case assigns.variant do
        "overlay" ->
          "border-2 border-white/50 bg-black/50 text-white hover:bg-black/70"

        _ ->
          "text-[color:var(--text-muted)] hover:text-[color:var(--text-primary)] hover:bg-[color:var(--bg-muted)]"
      end

    assigns =
      assigns
      |> assign(:button_type, if(link?, do: nil, else: assigns.type || "button"))
      |> assign(:button_class, [base_classes, size_classes, variant_classes, assigns.class])

    if link? do
      ~H"""
      <.link class={@button_class} aria-label={@label} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button type={@button_type} aria-label={@label} class={@button_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an emoji picker for composer-like forms.

  This component is purely client-side via the `EmojiPicker` LiveView hook.
  """
  attr :emojis, :list,
    default: ["😀", "😍", "🔥", "👍", "❤️", "🎉", "😮", "😢"],
    doc: "emoji options to render"

  attr :id, :string, default: nil, doc: "optional DOM id"
  attr :class, :any, default: nil, doc: "additional classes for the picker wrapper"

  def compose_emoji_picker(assigns) do
    ~H"""
    <div
      id={@id}
      class={["relative", @class]}
      data-role="compose-emoji-picker"
      phx-hook="EmojiPicker"
    >
      <button
        type="button"
        data-role="compose-emoji"
        aria-label="Emoji picker"
        aria-expanded="false"
        class="inline-flex h-10 w-10 items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)] focus-visible:outline-none"
      >
        <.icon name="hero-face-smile" class="size-5" />
      </button>

      <div
        data-role="compose-emoji-menu"
        data-state="closed"
        data-placement="bottom"
        class={[
          "absolute left-1/2 z-30 hidden max-h-72 w-64 -translate-x-1/2 overflow-y-auto border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-4 data-[placement=bottom]:top-full data-[placement=bottom]:mt-2 data-[placement=bottom]:bottom-auto data-[placement=bottom]:mb-0 data-[placement=top]:bottom-full data-[placement=top]:mb-2 data-[placement=top]:top-auto data-[placement=top]:mt-0"
        ]}
      >
        <p class="text-xs font-bold uppercase tracking-wider text-[color:var(--text-muted)]">
          Emoji
        </p>

        <div class="mt-3 grid grid-cols-8 gap-1">
          <button
            :for={emoji <- @emojis}
            type="button"
            data-role="compose-emoji-option"
            data-emoji={emoji}
            class="inline-flex h-9 w-9 items-center justify-center text-xl transition hover:bg-[color:var(--bg-muted)] focus-visible:outline-none"
          >
            {emoji}
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a surface container (card/panel) with consistent styling.
  """
  attr :rest, :global
  attr :class, :any, default: nil
  attr :data_role, :string, default: "card"
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section
      data-role={@data_role}
      class={[
        "border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)]",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Renders an actor/avatar image with a graceful initial fallback.
  """
  attr :rest, :global
  attr :class, :any, default: nil
  attr :data_role, :string, default: "avatar"
  attr :name, :string, required: true
  attr :src, :string, default: nil
  attr :alt, :string, default: nil
  attr :size, :string, values: ~w(xs sm md lg xl), default: "md"

  def avatar(assigns) do
    assigns = assign_new(assigns, :alt, fn -> assigns.name end)

    {box_classes, text_classes} =
      case assigns.size do
        "xs" -> {"h-7 w-7", "text-xs"}
        "sm" -> {"h-9 w-9", "text-sm"}
        "lg" -> {"h-14 w-14", "text-base"}
        "xl" -> {"h-16 w-16", "text-lg"}
        _ -> {"h-11 w-11", "text-sm"}
      end

    assigns =
      assigns
      |> assign(:box_classes, box_classes)
      |> assign(:text_classes, text_classes)
      |> assign(:initial, avatar_initial(assigns.name))

    ~H"""
    <span
      data-role={@data_role}
      class={[
        "inline-flex shrink-0 items-center justify-center overflow-hidden border-2 border-[color:var(--border-default)] bg-[color:var(--bg-subtle)]",
        @box_classes,
        @class
      ]}
      {@rest}
    >
      <%= if is_binary(@src) and @src != "" do %>
        <img src={@src} alt={@alt} class="h-full w-full object-cover" loading="lazy" />
      <% else %>
        <span class={["font-bold text-[color:var(--text-secondary)]", @text_classes]}>
          {@initial}
        </span>
      <% end %>
    </span>
    """
  end

  @doc false
  def upload_entry_kind(%{client_type: type}) when is_binary(type) do
    cond do
      String.starts_with?(type, "image/") -> :image
      String.starts_with?(type, "video/") -> :video
      String.starts_with?(type, "audio/") -> :audio
      true -> :other
    end
  end

  def upload_entry_kind(_entry), do: :other

  @doc false
  def upload_entry_icon(entry) do
    case upload_entry_kind(entry) do
      :video -> "hero-film"
      :audio -> "hero-musical-note"
      _ -> "hero-paper-clip"
    end
  end

  @doc false
  def upload_entry_description_placeholder(entry) do
    case upload_entry_kind(entry) do
      :image -> "Describe the image for screen readers"
      :video -> "Describe the video for screen readers"
      :audio -> "Describe the audio for screen readers"
      _ -> "Describe the attachment for screen readers"
    end
  end

  @doc """
  Renders a compact preview for an uploaded media entry.

  Designed for small thumbnail containers. Supports:
  - image previews (via built-in LiveView preview hook)
  - video thumbnails (first frame)
  - icons for audio/other files
  """
  attr :entry, :any, required: true
  attr :class, :any, default: nil
  attr :data_role, :string, default: "upload-preview"

  def upload_entry_preview(assigns) do
    assigns = assign(assigns, :kind, upload_entry_kind(assigns.entry))

    ~H"""
    <%= case @kind do %>
      <% :image -> %>
        <.live_img_preview
          entry={@entry}
          data-role={@data_role}
          data-kind="image"
          class={["h-full w-full object-cover", @class]}
        />
      <% :video -> %>
        <video
          id={"phx-preview-thumb-#{@entry.ref}"}
          data-phx-upload-ref={@entry.upload_ref}
          data-phx-entry-ref={@entry.ref}
          data-phx-hook="Phoenix.LiveImgPreview"
          data-phx-update="ignore"
          phx-no-format
          data-role={@data_role}
          data-kind="video"
          class={["h-full w-full bg-black object-cover", @class]}
          muted
          playsinline
          preload="metadata"
        >
        </video>

        <div class="pointer-events-none absolute inset-0 flex items-center justify-center">
          <span class="inline-flex h-8 w-8 items-center justify-center rounded-full bg-black/50 text-white">
            <.icon name="hero-play" class="size-4" />
          </span>
        </div>
      <% _ -> %>
        <div
          data-role={@data_role}
          data-kind={to_string(@kind)}
          class="flex h-full w-full items-center justify-center bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"
        >
          <.icon name={upload_entry_icon(@entry)} class="size-7" />
        </div>
    <% end %>
    """
  end

  @doc """
  Renders a full-width inline player for uploaded audio/video entries.

  Uses LiveView's built-in preview hook to set `src` on the element.
  """
  attr :entry, :any, required: true
  attr :class, :any, default: nil
  attr :data_role, :string, default: "upload-player"

  def upload_entry_player(assigns) do
    assigns = assign(assigns, :kind, upload_entry_kind(assigns.entry))

    ~H"""
    <%= case @kind do %>
      <% :video -> %>
        <video
          id={"phx-preview-player-#{@entry.ref}"}
          data-phx-upload-ref={@entry.upload_ref}
          data-phx-entry-ref={@entry.ref}
          data-phx-hook="Phoenix.LiveImgPreview"
          data-phx-update="ignore"
          phx-no-format
          data-role={@data_role}
          data-kind="video"
          class={["w-full rounded-lg bg-black shadow-sm", @class]}
          controls
          preload="metadata"
          playsinline
        >
        </video>
      <% :audio -> %>
        <audio
          id={"phx-preview-player-#{@entry.ref}"}
          data-phx-upload-ref={@entry.upload_ref}
          data-phx-entry-ref={@entry.ref}
          data-phx-hook="Phoenix.LiveImgPreview"
          data-phx-update="ignore"
          phx-no-format
          data-role={@data_role}
          data-kind="audio"
          class={["w-full", @class]}
          controls
          preload="metadata"
        >
        </audio>
      <% _ -> %>
    <% end %>
    """
  end

  @doc """
  Renders a human-friendly relative timestamp.
  """
  attr :at, :any, required: true
  attr :class, :any, default: nil
  attr :data_role, :string, default: "timestamp"

  def time_ago(assigns) do
    assigns =
      assigns
      |> assign(:iso, EgregorosWeb.Time.iso8601(assigns.at))
      |> assign(:label, EgregorosWeb.Time.relative(assigns.at))

    ~H"""
    <time
      :if={is_binary(@iso) and @iso != "" and is_binary(@label) and @label != ""}
      data-role={@data_role}
      datetime={@iso}
      title={@iso}
      class={["font-mono text-xs text-[color:var(--text-muted)]", @class]}
    >
      {@label}
    </time>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="space-y-1">
      <label class="inline-flex items-center gap-3 text-sm text-[color:var(--text-primary)]">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={[
            @class ||
              "h-4 w-4 border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] accent-[color:var(--text-primary)] focus:outline-none",
            @errors != [] && (@error_class || "border-[color:var(--danger)]")
          ]}
          {@rest}
        />
        <span :if={@label} class="select-none font-medium">{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label
        :if={@label}
        for={@id}
        class="block text-sm font-bold uppercase tracking-wide text-[color:var(--text-primary)]"
      >
        {@label}
      </label>
      <select
        id={@id}
        name={@name}
        class={[
          @class ||
            "w-full border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-sm text-[color:var(--text-primary)] outline-none transition focus:shadow-[4px_4px_0_var(--border-default)] focus:-translate-x-0.5 focus:-translate-y-0.5",
          @errors != [] && (@error_class || "border-[color:var(--danger)]")
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label
        :if={@label}
        for={@id}
        class="block text-sm font-bold uppercase tracking-wide text-[color:var(--text-primary)]"
      >
        {@label}
      </label>
      <textarea
        id={@id}
        name={@name}
        class={[
          @class ||
            "w-full resize-none border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-sm text-[color:var(--text-primary)] outline-none transition focus:shadow-[4px_4px_0_var(--border-default)] focus:-translate-x-0.5 focus:-translate-y-0.5",
          @errors != [] && (@error_class || "border-[color:var(--danger)]")
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label
        :if={@label}
        for={@id}
        class="block text-sm font-bold uppercase tracking-wide text-[color:var(--text-primary)]"
      >
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          @class ||
            "w-full border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-sm text-[color:var(--text-primary)] outline-none transition focus:shadow-[4px_4px_0_var(--border-default)] focus:-translate-x-0.5 focus:-translate-y-0.5",
          @errors != [] && (@error_class || "border-[color:var(--danger)]")
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1 flex items-center gap-2 text-sm font-bold text-[color:var(--danger)]">
      <span class="font-mono">[!]</span>
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4 border-b-2 border-[color:var(--border-default)]"]}>
      <div>
        <h1 class="text-lg font-bold uppercase tracking-wide text-[color:var(--text-primary)]">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-[color:var(--text-secondary)]">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)]">
      <table class="min-w-full divide-y-2 divide-[color:var(--border-default)] text-sm">
        <thead class="bg-[color:var(--bg-subtle)]">
          <tr>
            <th
              :for={col <- @col}
              scope="col"
              class="px-4 py-3 text-left text-xs font-bold uppercase tracking-wider text-[color:var(--text-secondary)]"
            >
              {col[:label]}
            </th>
            <th
              :if={@action != []}
              scope="col"
              class="px-4 py-3 text-right text-xs font-bold uppercase tracking-wider text-[color:var(--text-secondary)]"
            >
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
          class="divide-y divide-[color:var(--border-muted)]"
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="transition hover:bg-[color:var(--bg-subtle)]"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[
                "px-4 py-3 align-top text-[color:var(--text-primary)]",
                @row_click && "cursor-pointer"
              ]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="px-4 py-3 text-right align-top">
              <div class="inline-flex items-center justify-end gap-3">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="divide-y divide-[color:var(--border-muted)] border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] text-sm">
      <div
        :for={item <- @item}
        class="flex flex-col gap-1 px-4 py-3 sm:flex-row sm:items-start sm:justify-between"
      >
        <dt class="text-xs font-bold uppercase tracking-wider text-[color:var(--text-muted)]">
          {item.title}
        </dt>
        <dd class="font-medium text-[color:var(--text-primary)]">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-out duration-200", "opacity-0 translate-y-2",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 translate-y-2"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(EgregorosWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(EgregorosWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders inline text with custom emoji shortcodes replaced by safe `<img>` tags.
  """
  def emoji_inline(text, emojis \\ []) do
    text =
      text
      |> case do
        nil -> ""
        value -> to_string(value)
      end
      |> String.trim()

    HTML.to_safe_inline_html(text, emojis: List.wrap(emojis))
    |> Phoenix.HTML.raw()
  end

  defp avatar_initial(name) when is_binary(name) do
    name
    |> String.trim()
    |> case do
      "" -> "?"
      trimmed -> trimmed |> String.first() |> String.upcase()
    end
  end

  defp avatar_initial(_name), do: "?"
end
