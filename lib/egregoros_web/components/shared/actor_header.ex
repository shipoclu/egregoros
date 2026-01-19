defmodule EgregorosWeb.Components.Shared.ActorHeader do
  @moduledoc """
  Shared component for rendering actor information (avatar, name, handle, badges).
  Used in status cards, notifications, and other contexts where actor info is displayed.
  """
  use EgregorosWeb, :html

  alias EgregorosWeb.ProfilePaths

  attr :actor, :map, required: true
  attr :object, :map, default: nil
  attr :size, :atom, default: :default, values: [:default, :small, :compact]
  attr :show_badge, :boolean, default: true
  attr :link, :boolean, default: true

  def actor_header(assigns) do
    profile_path = actor_profile_path(assigns.actor)
    assigns = assign(assigns, :profile_path, profile_path)

    ~H"""
    <div class={[
      "flex min-w-0 items-start gap-3",
      @size == :small && "gap-2",
      @size == :compact && "gap-2"
    ]}>
      <%= if @link and is_binary(@profile_path) do %>
        <.link
          navigate={@profile_path}
          data-role="actor-link"
          class="group flex min-w-0 items-start gap-3 focus-visible:outline-none"
        >
          <div class="shrink-0">
            <.actor_avatar actor={@actor} size={@size} />
          </div>

          <div class="min-w-0">
            <.actor_name actor={@actor} size={@size} linked?={true} />
            <.actor_meta actor={@actor} object={@object} size={@size} show_badge={@show_badge} />
          </div>
        </.link>
      <% else %>
        <div class="shrink-0">
          <.actor_avatar actor={@actor} size={@size} />
        </div>

        <div class="min-w-0">
          <.actor_name actor={@actor} size={@size} linked?={false} />
          <.actor_meta actor={@actor} object={@object} size={@size} show_badge={@show_badge} />
        </div>
      <% end %>
    </div>
    """
  end

  attr :actor, :map, required: true
  attr :size, :atom, default: :default

  def actor_avatar(assigns) do
    assigns =
      assign_new(assigns, :avatar_class, fn ->
        case assigns.size do
          :compact -> "h-8 w-8"
          :small -> "h-9 w-9"
          _ -> "h-11 w-11"
        end
      end)

    ~H"""
    <%= if is_binary(@actor.avatar_url) and @actor.avatar_url != "" do %>
      <img
        src={@actor.avatar_url}
        alt={@actor.display_name}
        class={[
          @avatar_class,
          "border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] object-cover"
        ]}
        loading="lazy"
      />
    <% else %>
      <div class={[
        @avatar_class,
        "flex items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] font-bold text-[color:var(--text-secondary)]"
      ]}>
        {avatar_initial(@actor.display_name)}
      </div>
    <% end %>
    """
  end

  attr :actor, :map, required: true
  attr :size, :atom, default: :default
  attr :linked?, :boolean, default: false

  defp actor_name(assigns) do
    ~H"""
    <p
      data-role="post-actor-name"
      class={[
        "truncate font-bold text-[color:var(--text-primary)]",
        @linked? && "group-hover:underline underline-offset-2",
        @size == :compact && "text-sm"
      ]}
    >
      {emoji_inline(
        Map.get(@actor, :display_name) || Map.get(@actor, "display_name"),
        Map.get(@actor, :emojis) || Map.get(@actor, "emojis") || []
      )}
    </p>
    """
  end

  attr :actor, :map, required: true
  attr :object, :map, default: nil
  attr :size, :atom, default: :default
  attr :show_badge, :boolean, default: true

  defp actor_meta(assigns) do
    ~H"""
    <div class={[
      "mt-0.5 flex flex-wrap items-center gap-2",
      @size == :compact && "mt-0"
    ]}>
      <span
        data-role="post-actor-handle"
        class={[
          "truncate font-mono text-[color:var(--text-muted)]",
          @size == :compact && "text-xs",
          @size != :compact && "text-sm"
        ]}
      >
        {@actor.handle}
      </span>

      <span
        :if={@show_badge and @object}
        class={[
          "inline-flex items-center border px-1.5 py-0.5 font-mono text-[10px] font-bold uppercase tracking-wide",
          @object.local && "border-[color:var(--success)] text-[color:var(--success)]",
          !@object.local && "border-[color:var(--border-muted)] text-[color:var(--text-muted)]"
        ]}
      >
        {if @object.local, do: "local", else: "remote"}
      </span>
    </div>
    """
  end

  defp actor_profile_path(actor), do: ProfilePaths.profile_path(actor)

  defp avatar_initial(name) when is_binary(name) do
    name = String.trim(name)

    case String.first(name) do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end

  defp avatar_initial(_), do: "?"
end
