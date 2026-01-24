defmodule EgregorosWeb.ComposerPoll do
  use EgregorosWeb, :html

  @moduledoc false

  attr :id_prefix, :string, required: true
  attr :open?, :boolean, default: false
  attr :toggle_event, :string, required: true

  def poll_toggle_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@id_prefix}-poll-toggle"}
      data-role="compose-toggle-poll"
      phx-click={@toggle_event}
      aria-pressed={if @open?, do: "true", else: "false"}
      aria-label="Toggle poll"
      class={[
        "inline-flex h-10 w-10 items-center justify-center transition focus-visible:outline-none focus-brutal",
        @open? && "bg-[color:var(--bg-muted)] text-[color:var(--text-primary)]",
        !@open? &&
          "text-[color:var(--text-muted)] hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)]"
      ]}
    >
      <.icon name="hero-chart-bar" class="size-5" />
      <span class="sr-only">Add poll</span>
    </button>
    """
  end

  attr :id_prefix, :string, required: true
  attr :param_prefix, :string, required: true
  attr :open?, :boolean, default: false
  attr :poll, :map, default: %{}
  attr :add_event, :string, required: true
  attr :remove_event, :string, required: true
  attr :max_options, :integer, default: 4
  attr :min_options, :integer, default: 2

  def poll_fields(assigns) do
    assigns =
      assigns
      |> assign_new(:panel_id, fn -> "#{assigns.id_prefix}-poll-panel" end)
      |> assign_new(:options, fn -> poll_options(assigns.poll, assigns.min_options) end)
      |> assign_new(:multiple?, fn -> poll_multiple?(assigns.poll) end)
      |> assign_new(:expires_in, fn -> poll_expires_in(assigns.poll) end)

    ~H"""
    <div
      id={@panel_id}
      data-role="compose-poll"
      data-state={if @open?, do: "open", else: "closed"}
      class={[
        "border-t border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] px-4 py-4",
        !@open? && "hidden"
      ]}
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p class="text-xs font-bold uppercase tracking-wider text-[color:var(--text-muted)]">
            Poll options
          </p>
          <p class="mt-1 text-xs text-[color:var(--text-muted)]">
            Add 2 to {@max_options} options. Options must be unique.
          </p>
        </div>

        <button
          type="button"
          data-role="compose-poll-add"
          phx-click={@add_event}
          disabled={length(@options) >= @max_options}
          class={[
            "inline-flex items-center gap-2 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-xs font-bold uppercase tracking-wide transition focus-visible:outline-none focus-brutal",
            length(@options) >= @max_options &&
              "cursor-not-allowed border-[color:var(--border-muted)] text-[color:var(--text-muted)]",
            length(@options) < @max_options &&
              "text-[color:var(--text-primary)] hover:bg-[color:var(--bg-muted)]"
          ]}
        >
          <.icon name="hero-plus-small" class="size-4" /> Add option
        </button>
      </div>

      <div class="mt-4 space-y-3">
        <div
          :for={{option, index} <- Enum.with_index(@options)}
          data-role="compose-poll-option"
          class="flex flex-wrap items-center gap-3"
        >
          <div class="min-w-[12rem] flex-1">
            <.input
              type="text"
              id={"#{@id_prefix}-poll-option-#{index}"}
              name={"#{@param_prefix}[poll][options][]"}
              value={option}
              placeholder={"Option #{index + 1}"}
            />
          </div>

          <button
            type="button"
            data-role="compose-poll-remove"
            phx-click={@remove_event}
            phx-value-index={index}
            disabled={length(@options) <= @min_options}
            aria-label={"Remove option #{index + 1}"}
            class={[
              "inline-flex h-10 w-10 items-center justify-center border border-[color:var(--border-default)] bg-[color:var(--bg-base)] text-[color:var(--text-muted)] transition focus-visible:outline-none focus-brutal",
              length(@options) <= @min_options &&
                "cursor-not-allowed border-[color:var(--border-muted)] opacity-50",
              length(@options) > @min_options &&
                "hover:bg-[color:var(--bg-muted)] hover:text-[color:var(--text-primary)]"
            ]}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>

      <div class="mt-4 grid gap-4 sm:grid-cols-2">
        <.input
          type="checkbox"
          name={"#{@param_prefix}[poll][multiple]"}
          value="true"
          checked={@multiple?}
          label="Allow multiple choices"
        />

        <.input
          type="select"
          name={"#{@param_prefix}[poll][expires_in]"}
          value={@expires_in}
          label="Poll length"
          options={expiration_options()}
        />
      </div>
    </div>
    """
  end

  defp poll_options(poll, min_options) when is_map(poll) do
    options =
      poll
      |> Map.get("options")
      |> Kernel.||(Map.get(poll, :options))
      |> List.wrap()
      |> Enum.map(&to_string/1)

    if length(options) < min_options do
      options ++ List.duplicate("", min_options - length(options))
    else
      options
    end
  end

  defp poll_options(_poll, min_options), do: List.duplicate("", min_options)

  defp poll_multiple?(poll) when is_map(poll) do
    case Map.get(poll, "multiple") || Map.get(poll, :multiple) do
      true -> true
      1 -> true
      "1" -> true
      "true" -> true
      _ -> false
    end
  end

  defp poll_multiple?(_poll), do: false

  defp poll_expires_in(poll) when is_map(poll) do
    poll
    |> Map.get("expires_in")
    |> Kernel.||(Map.get(poll, :expires_in))
    |> normalize_expires_in()
  end

  defp poll_expires_in(_poll), do: normalize_expires_in(nil)

  defp normalize_expires_in(value) when is_integer(value), do: value

  defp normalize_expires_in(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 3600
    end
  end

  defp normalize_expires_in(_value), do: 3600

  defp expiration_options do
    [
      {"1 hour", 3600},
      {"6 hours", 21_600},
      {"1 day", 86_400},
      {"3 days", 259_200},
      {"7 days", 604_800}
    ]
  end
end
