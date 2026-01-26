defmodule EgregorosWeb.Components.Shared.InteractionBar do
  @moduledoc """
  Shared component for rendering interaction buttons (reply, like, repost, reactions).
  Used in status cards for timeline and individual post views.
  """
  use EgregorosWeb, :html

  alias Egregoros.Domain
  alias Egregoros.Mentions

  @default_reactions ["🔥", "👍", "❤️"]

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :current_user, :any, default: nil
  attr :reply_mode, :atom, default: :navigate

  def interaction_bar(assigns) do
    assigns = assign_new(assigns, :feed_id, fn -> feed_id_for_entry(assigns.entry) end)

    ~H"""
    <div
      :if={@current_user}
      class="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-[color:var(--border-muted)] pt-4"
    >
      <div class="flex flex-wrap items-center gap-2">
        <.reply_button
          id={@id}
          entry={@entry}
          reply_mode={@reply_mode}
        />

        <.like_button entry={@entry} feed_id={@feed_id} />
        <.repost_button entry={@entry} feed_id={@feed_id} />
      </div>

      <.reactions_bar id={@id} entry={@entry} feed_id={@feed_id} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :reply_mode, :atom, default: :navigate

  defp reply_button(assigns) do
    assigns =
      assign_new(assigns, :mention_handles, fn ->
        mention_handles_for_entry(assigns.entry)
      end)

    ~H"""
    <%= if @reply_mode == :modal do %>
      <button
        type="button"
        data-role="reply"
        phx-click={
          JS.dispatch("egregoros:reply-open",
            to: "#reply-modal",
            detail: %{
              in_reply_to: @entry.object.ap_id,
              actor_handle: @entry.actor.handle,
              mention_handles: @mention_handles
            }
          )
        }
        class="inline-flex cursor-pointer items-center gap-2 border border-[color:var(--border-muted)] bg-[color:var(--bg-base)] px-3 py-2 text-sm font-medium text-[color:var(--text-secondary)] transition hover:border-[color:var(--border-default)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal"
        aria-label="Reply"
      >
        <.icon name="hero-chat-bubble-left-right" class="size-5" />
        <span class="sr-only">Reply</span>
      </button>
    <% else %>
      <%= if is_binary(reply_path = status_reply_path(@entry)) do %>
        <.link
          navigate={reply_path}
          data-role="reply"
          class="inline-flex cursor-pointer items-center gap-2 border border-[color:var(--border-muted)] bg-[color:var(--bg-base)] px-3 py-2 text-sm font-medium text-[color:var(--text-secondary)] transition hover:border-[color:var(--border-default)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal"
          aria-label="Reply"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-5" />
          <span class="sr-only">Reply</span>
        </.link>
      <% end %>
    <% end %>
    """
  end

  attr :entry, :map, required: true
  attr :feed_id, :any, required: true

  defp like_button(assigns) do
    ~H"""
    <button
      type="button"
      data-role="like"
      aria-pressed={if @entry.liked?, do: "true", else: "false"}
      data-pressed={if @entry.liked?, do: "true", else: "false"}
      phx-click={
        JS.dispatch("egregoros:optimistic-toggle", detail: %{kind: "like"})
        |> JS.push("toggle_like", value: %{"id" => @entry.object.id, "feed_id" => @feed_id})
      }
      class={[
        "inline-flex cursor-pointer items-center gap-2 border px-3 py-2 text-sm font-medium transition focus-visible:outline-none focus-brutal",
        "data-[pressed=true]:border-[color:var(--danger)] data-[pressed=true]:bg-[color:var(--danger-subtle)] data-[pressed=true]:text-[color:var(--danger)]",
        "data-[pressed=false]:border-[color:var(--border-muted)] data-[pressed=false]:bg-[color:var(--bg-base)] data-[pressed=false]:text-[color:var(--text-secondary)] data-[pressed=false]:hover:border-[color:var(--border-default)] data-[pressed=false]:hover:text-[color:var(--text-primary)]"
      ]}
    >
      <.icon
        name={if @entry.liked?, do: "hero-heart-solid", else: "hero-heart"}
        class="size-5"
      />
      <span class="sr-only">{if @entry.liked?, do: "Unlike", else: "Like"}</span>
      <span class="font-mono text-xs font-bold tabular-nums">
        {@entry.likes_count}
      </span>
    </button>
    """
  end

  attr :entry, :map, required: true
  attr :feed_id, :any, required: true

  defp repost_button(assigns) do
    ~H"""
    <button
      type="button"
      data-role="repost"
      aria-pressed={if @entry.reposted?, do: "true", else: "false"}
      data-pressed={if @entry.reposted?, do: "true", else: "false"}
      phx-click={
        JS.dispatch("egregoros:optimistic-toggle", detail: %{kind: "repost"})
        |> JS.push("toggle_repost", value: %{"id" => @entry.object.id, "feed_id" => @feed_id})
      }
      class={[
        "inline-flex cursor-pointer items-center gap-2 border px-3 py-2 text-sm font-medium transition focus-visible:outline-none focus-brutal",
        "data-[pressed=true]:border-[color:var(--success)] data-[pressed=true]:bg-[color:var(--success-subtle)] data-[pressed=true]:text-[color:var(--success)]",
        "data-[pressed=false]:border-[color:var(--border-muted)] data-[pressed=false]:bg-[color:var(--bg-base)] data-[pressed=false]:text-[color:var(--text-secondary)] data-[pressed=false]:hover:border-[color:var(--border-default)] data-[pressed=false]:hover:text-[color:var(--text-primary)]"
      ]}
    >
      <.icon
        name={if @entry.reposted?, do: "hero-arrow-path-solid", else: "hero-arrow-path"}
        class="size-5"
      />
      <span class="sr-only">{if @entry.reposted?, do: "Unrepost", else: "Repost"}</span>
      <span class="font-mono text-xs font-bold tabular-nums">
        {@entry.reposts_count}
      </span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :feed_id, :any, required: true

  defp reactions_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <%= for emoji <- reaction_order(@entry.reactions) do %>
        <% reaction =
          Map.get(@entry.reactions || %{}, emoji, %{count: 0, reacted?: false, url: nil}) %>

        <.reaction_button
          id={@id}
          entry={@entry}
          feed_id={@feed_id}
          emoji={emoji}
          reaction={reaction}
        />
      <% end %>

      <.reaction_picker id={@id} entry={@entry} feed_id={@feed_id} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :feed_id, :any, required: true
  attr :emoji, :string, required: true
  attr :reaction, :map, required: true

  defp reaction_button(assigns) do
    ~H"""
    <button
      type="button"
      data-role="reaction"
      data-emoji={@emoji}
      aria-pressed={if @reaction.reacted?, do: "true", else: "false"}
      data-pressed={if @reaction.reacted?, do: "true", else: "false"}
      phx-click={
        JS.dispatch("egregoros:optimistic-toggle", detail: %{kind: "reaction"})
        |> JS.push("toggle_reaction",
          value: %{
            "id" => @entry.object.id,
            "feed_id" => @feed_id,
            "emoji" => @emoji
          }
        )
      }
      class={[
        "inline-flex cursor-pointer items-center gap-2 border px-3 py-2 text-sm font-medium transition focus-visible:outline-none focus-brutal",
        "data-[pressed=true]:border-[color:var(--success)] data-[pressed=true]:bg-[color:var(--success-subtle)] data-[pressed=true]:text-[color:var(--success)]",
        "data-[pressed=false]:border-[color:var(--border-muted)] data-[pressed=false]:bg-[color:var(--bg-base)] data-[pressed=false]:text-[color:var(--text-secondary)] data-[pressed=false]:hover:border-[color:var(--border-default)] data-[pressed=false]:hover:text-[color:var(--text-primary)]"
      ]}
    >
      <span class="text-base leading-none">
        <% url = Map.get(@reaction, :url) %>
        <%= if is_binary(url) and url != "" do %>
          {emoji_inline(":#{@emoji}:", [%{shortcode: @emoji, url: url}])}
        <% else %>
          {@emoji}
        <% end %>
      </span>
      <span class="font-mono text-xs font-bold tabular-nums">{@reaction.count || 0}</span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :feed_id, :any, required: true

  defp reaction_picker(assigns) do
    ~H"""
    <div
      id={"reaction-picker-#{@id}"}
      data-role="reaction-picker"
      phx-hook="ReactionPicker"
      data-post-id={@entry.object.id}
      data-feed-id={@feed_id}
      class="relative"
    >
      <button
        type="button"
        data-role="reaction-picker-toggle"
        aria-label="Add reaction"
        aria-haspopup="menu"
        aria-expanded="false"
        class="inline-flex h-9 w-9 cursor-pointer items-center justify-center border border-[color:var(--border-muted)] bg-[color:var(--bg-base)] text-[color:var(--text-muted)] transition hover:border-[color:var(--border-default)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal"
      >
        <.icon name="hero-face-smile" class="size-5" />
      </button>

      <div
        data-role="reaction-picker-menu"
        data-state="closed"
        aria-hidden="true"
        class={[
          "absolute right-0 top-full z-40 mt-2 w-64 overflow-hidden p-4",
          "hidden border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)]",
          "shadow-[4px_4px_0_var(--border-default)] motion-safe:animate-rise"
        ]}
      >
        <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
          React
        </p>

        <div data-role="reaction-picker-grid" class="mt-3 grid grid-cols-8 gap-1"></div>
      </div>
    </div>
    """
  end

  defp reaction_order(%{} = reactions) do
    custom =
      reactions
      |> Map.keys()
      |> Enum.reject(&(&1 in @default_reactions))
      |> Enum.sort()

    (@default_reactions ++ custom)
    |> Enum.uniq()
  end

  defp reaction_order(_reactions), do: @default_reactions

  defp feed_id_for_entry(%{feed_id: id}) when is_binary(id), do: id
  defp feed_id_for_entry(%{object: %{id: id}}) when is_binary(id), do: id
  defp feed_id_for_entry(%{object: %{"id" => id}}) when is_binary(id), do: id
  defp feed_id_for_entry(_entry), do: nil

  defp mention_handles_for_entry(%{object: object}) do
    local_domains = local_domains()

    object
    |> mention_tags()
    |> Enum.flat_map(&mention_handle_from_tag(&1, local_domains))
    |> Enum.uniq()
  end

  defp mention_handles_for_entry(_entry), do: []

  defp mention_tags(object) when is_map(object) do
    data = Map.get(object, :data) || Map.get(object, "data") || %{}

    data
    |> Map.get("tag", Map.get(data, :tag, []))
    |> List.wrap()
  end

  defp mention_tags(_object), do: []

  defp mention_handle_from_tag(tag, local_domains) when is_list(local_domains) do
    {name, href} =
      case tag do
        %{"type" => "Mention"} = tag ->
          {Map.get(tag, "name") || Map.get(tag, :name),
           Map.get(tag, "href") || Map.get(tag, :href) || Map.get(tag, "id") || Map.get(tag, :id)}

        %{type: "Mention"} = tag ->
          {Map.get(tag, :name) || Map.get(tag, "name"),
           Map.get(tag, :href) || Map.get(tag, "href") || Map.get(tag, :id) || Map.get(tag, "id")}

        _ ->
          {nil, nil}
      end

    with handle when is_binary(handle) <- handle_for_prefill(name, href, local_domains) do
      [handle]
    else
      _ -> []
    end
  end

  defp mention_handle_from_tag(_tag, _local_domains), do: []

  defp handle_for_prefill(name, href, local_domains)
       when is_binary(name) and is_list(local_domains) do
    name = name |> String.trim() |> String.trim_leading("@")

    case Mentions.parse(name) do
      {:ok, nickname, host} ->
        host = host || mention_host_from_href(href)

        cond do
          is_binary(host) and host != "" and host not in local_domains -> "@#{nickname}@#{host}"
          true -> "@#{nickname}"
        end

      :error ->
        nil
    end
  end

  defp handle_for_prefill(_name, _href, _local_domains), do: nil

  defp mention_host_from_href(href) when is_binary(href) do
    href = String.trim(href)

    if href == "" do
      nil
    else
      href |> URI.parse() |> Domain.from_uri()
    end
  end

  defp mention_host_from_href(_href), do: nil

  defp local_domains do
    case URI.parse(EgregorosWeb.Endpoint.url()) do
      %URI{} = uri -> Domain.aliases_from_uri(uri)
      _ -> []
    end
  end

  defp status_reply_path(entry) do
    case status_permalink_path(entry) do
      path when is_binary(path) and path != "" -> path <> "?reply=true#reply-form"
      _ -> nil
    end
  end

  defp status_permalink_path(%{object: %{local: true} = object, actor: %{nickname: nickname}})
       when is_binary(nickname) and nickname != "" do
    case EgregorosWeb.URL.local_object_uuid(Map.get(object, :ap_id)) do
      uuid when is_binary(uuid) and uuid != "" -> "/@#{nickname}/#{uuid}"
      _ -> nil
    end
  end

  defp status_permalink_path(%{object: %{id: id, local: false}, actor: actor})
       when is_binary(id) do
    case EgregorosWeb.ProfilePaths.profile_path(actor) do
      "/@" <> _rest = profile_path -> profile_path <> "/" <> id
      _ -> nil
    end
  end

  defp status_permalink_path(_entry), do: nil
end
