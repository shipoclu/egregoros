defmodule EgregorosWeb.StatusCard do
  use EgregorosWeb, :html

  alias Egregoros.CustomEmojis
  alias Egregoros.HTML
  alias Egregoros.User
  alias EgregorosWeb.ProfilePaths
  alias EgregorosWeb.URL

  @content_collapse_threshold 500
  @default_reactions ["🔥", "👍", "❤️"]

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :current_user, :any, default: nil
  attr :back_timeline, :any, default: nil
  attr :reply_mode, :atom, default: :navigate

  def status_card(assigns) do
    ~H"""
    <article
      id={@id}
      data-role="status-card"
      class="scroll-mt-24 border-b border-[color:var(--border-muted)] bg-[color:var(--bg-base)] p-5 transition hover:bg-[color:var(--bg-subtle)] target:ring-2 target:ring-[color:var(--border-default)]"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="flex min-w-0 items-start gap-3">
          <%= if is_binary(profile_path = actor_profile_path(@entry.actor)) do %>
            <.link
              navigate={profile_path}
              data-role="actor-link"
              class="group flex min-w-0 items-start gap-3 focus-visible:outline-none"
            >
              <div class="shrink-0">
                <.actor_avatar actor={@entry.actor} />
              </div>

              <div class="min-w-0">
                <p
                  data-role="post-actor-name"
                  class="truncate font-bold text-[color:var(--text-primary)] group-hover:underline underline-offset-2"
                >
                  {emoji_inline(
                    Map.get(@entry.actor, :display_name) || Map.get(@entry.actor, "display_name"),
                    Map.get(@entry.actor, :emojis) || Map.get(@entry.actor, "emojis") || []
                  )}
                </p>
                <div class="mt-0.5 flex flex-wrap items-center gap-2">
                  <span
                    data-role="post-actor-handle"
                    class="truncate font-mono text-sm text-[color:var(--text-muted)]"
                  >
                    {@entry.actor.handle}
                  </span>

                  <span class={[
                    "inline-flex items-center border px-1.5 py-0.5 font-mono text-[10px] font-bold uppercase tracking-wide",
                    @entry.object.local &&
                      "border-[color:var(--success)] text-[color:var(--success)]",
                    !@entry.object.local &&
                      "border-[color:var(--border-muted)] text-[color:var(--text-muted)]"
                  ]}>
                    {if @entry.object.local, do: "local", else: "remote"}
                  </span>
                </div>
              </div>
            </.link>
          <% else %>
            <div class="shrink-0">
              <.actor_avatar actor={@entry.actor} />
            </div>

            <div class="min-w-0">
              <p
                data-role="post-actor-name"
                class="truncate font-bold text-[color:var(--text-primary)]"
              >
                {emoji_inline(
                  Map.get(@entry.actor, :display_name) || Map.get(@entry.actor, "display_name"),
                  Map.get(@entry.actor, :emojis) || Map.get(@entry.actor, "emojis") || []
                )}
              </p>
              <div class="mt-0.5 flex flex-wrap items-center gap-2">
                <span
                  data-role="post-actor-handle"
                  class="truncate font-mono text-sm text-[color:var(--text-muted)]"
                >
                  {@entry.actor.handle}
                </span>

                <span class={[
                  "inline-flex items-center border px-1.5 py-0.5 font-mono text-[10px] font-bold uppercase tracking-wide",
                  @entry.object.local &&
                    "border-[color:var(--success)] text-[color:var(--success)]",
                  !@entry.object.local &&
                    "border-[color:var(--border-muted)] text-[color:var(--text-muted)]"
                ]}>
                  {if @entry.object.local, do: "local", else: "remote"}
                </span>
              </div>
            </div>
          <% end %>
        </div>

        <div class="flex items-center gap-2">
          <%= if is_binary(permalink_path = status_permalink_path(@entry)) do %>
            <.link
              navigate={with_back_timeline(permalink_path, @back_timeline)}
              data-role="post-permalink"
              class="inline-flex hover:underline underline-offset-2 focus-visible:outline-none focus-brutal"
              aria-label="Open post"
            >
              <.time_ago at={@entry.object.inserted_at} />
            </.link>
          <% else %>
            <.time_ago at={@entry.object.inserted_at} />
          <% end %>

          <.status_menu card_id={@id} entry={@entry} current_user={@current_user} />
        </div>
      </div>

      <% content_warning = content_warning_text(@entry.object) %>

      <%= if is_binary(content_warning) do %>
        <details data-role="content-warning" class="group mt-4">
          <summary class="flex cursor-pointer items-center justify-between gap-4 border-2 border-[color:var(--warning)] bg-[color:var(--warning-subtle)] px-4 py-3 text-left transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal list-none [&::-webkit-details-marker]:hidden">
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
                  title={content_warning}
                >
                  {content_warning}
                </p>
              </div>
            </div>

            <span class="inline-flex shrink-0 items-center gap-2 border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--text-primary)]">
              <span class="group-open:hidden">Show</span>
              <span class="hidden group-open:inline">Hide</span>
              <.icon name="hero-chevron-down" class="size-4 transition group-open:rotate-180" />
            </span>
          </summary>

          <.status_body entry={@entry} current_user={@current_user} />
        </details>
      <% else %>
        <.status_body entry={@entry} current_user={@current_user} />
      <% end %>

      <div
        :if={@current_user}
        class="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-[color:var(--border-muted)] pt-4"
      >
        <div class="flex flex-wrap items-center gap-2">
          <%= if @reply_mode == :modal do %>
            <button
              type="button"
              data-role="reply"
              phx-click={
                JS.dispatch("egregoros:reply-open",
                  to: "#reply-modal",
                  detail: %{
                    in_reply_to: @entry.object.ap_id,
                    actor_handle: @entry.actor.handle
                  }
                )
                |> JS.push("open_reply_modal",
                  value: %{
                    "in_reply_to" => @entry.object.ap_id,
                    "actor_handle" => @entry.actor.handle
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

          <button
            type="button"
            data-role="like"
            aria-pressed={@entry.liked?}
            data-pressed={if @entry.liked?, do: "true", else: "false"}
            phx-click={
              JS.dispatch("egregoros:optimistic-toggle", detail: %{kind: "like"})
              |> JS.push("toggle_like", value: %{"id" => @entry.object.id})
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

          <button
            type="button"
            data-role="repost"
            aria-pressed={@entry.reposted?}
            data-pressed={if @entry.reposted?, do: "true", else: "false"}
            phx-click={
              JS.dispatch("egregoros:optimistic-toggle", detail: %{kind: "repost"})
              |> JS.push("toggle_repost", value: %{"id" => @entry.object.id})
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
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <%= for emoji <- reaction_order(@entry.reactions) do %>
            <% reaction =
              Map.get(@entry.reactions || %{}, emoji, %{count: 0, reacted?: false, url: nil}) %>

            <button
              type="button"
              data-role="reaction"
              data-emoji={emoji}
              aria-pressed={reaction.reacted?}
              data-pressed={if reaction.reacted?, do: "true", else: "false"}
              phx-click={
                JS.dispatch("egregoros:optimistic-toggle", detail: %{kind: "reaction"})
                |> JS.push("toggle_reaction",
                  value: %{
                    "id" => @entry.object.id,
                    "emoji" => emoji
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
                <% url = Map.get(reaction, :url) %>
                <%= if is_binary(url) and url != "" do %>
                  {emoji_inline(":#{emoji}:", [%{shortcode: emoji, url: url}])}
                <% else %>
                  {emoji}
                <% end %>
              </span>
              <span class="font-mono text-xs font-bold tabular-nums">{reaction.count || 0}</span>
            </button>
          <% end %>

          <details
            id={"reaction-picker-#{@entry.object.id}"}
            data-role="reaction-picker"
            class="relative"
          >
            <summary class="list-none cursor-pointer [&::-webkit-details-marker]:hidden">
              <span class="inline-flex h-9 w-9 items-center justify-center border border-[color:var(--border-muted)] bg-[color:var(--bg-base)] text-[color:var(--text-muted)] transition hover:border-[color:var(--border-default)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal">
                <.icon name="hero-face-smile" class="size-5" />
                <span class="sr-only">Add reaction</span>
              </span>
            </summary>

            <div
              class="absolute right-0 top-11 z-40 w-64 overflow-hidden border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-4"
              phx-click-away={JS.remove_attribute("open", to: "#reaction-picker-#{@entry.object.id}")}
            >
              <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
                React
              </p>

              <div class="mt-3 grid grid-cols-8 gap-1">
                <button
                  :for={emoji <- reaction_picker_emojis()}
                  type="button"
                  data-role="reaction-picker-option"
                  data-emoji={emoji}
                  phx-click={
                    JS.dispatch("egregoros:optimistic-toggle", detail: %{kind: "reaction"})
                    |> JS.push("toggle_reaction",
                      value: %{
                        "id" => @entry.object.id,
                        "emoji" => emoji
                      }
                    )
                    |> JS.remove_attribute("open", to: "#reaction-picker-#{@entry.object.id}")
                  }
                  class="inline-flex cursor-pointer h-9 w-9 items-center justify-center text-xl transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
                >
                  {emoji}
                </button>
              </div>
            </div>
          </details>
        </div>
      </div>
    </article>
    """
  end

  defp reaction_picker_emojis do
    ["😀", "😂", "😍", "😮", "😢", "😡", "🔥", "👍", "❤️", "🎉", "🙏", "🤔", "🥳", "😎", "💯", "✨"]
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

  attr :entry, :map, required: true
  attr :current_user, :any, default: nil

  defp status_body(assigns) do
    ~H"""
    <% sensitive_media = sensitive_media?(@entry.object) %>
    <% collapsible_content = long_content?(@entry.object) %>
    <% attachments_layout = attachments_layout(@entry.attachments) %>
    <% content_id = "post-content-#{@entry.object.id}" %>
    <% fade_id = "#{content_id}-fade" %>
    <% toggle_more_id = "#{content_id}-more" %>
    <% toggle_less_id = "#{content_id}-less" %>
    <% toggle_icon_id = "#{content_id}-icon" %>
    <% e2ee_payload = e2ee_payload_json(@entry.object) %>
    <% current_user_ap_id = current_user_ap_id(@current_user) %>

    <div
      id={content_id}
      data-role="post-content"
      data-e2ee-dm={e2ee_payload}
      data-current-user-ap-id={current_user_ap_id}
      phx-hook={if is_binary(e2ee_payload), do: "E2EEDMMessage", else: nil}
      class={[
        "mt-4 break-words text-base leading-relaxed text-[color:var(--text-secondary)] [&_a]:font-medium [&_a]:text-[color:var(--link)] [&_a]:underline [&_a]:underline-offset-2 [&_a:hover]:text-[color:var(--text-primary)]",
        is_binary(e2ee_payload) && "whitespace-pre-wrap",
        collapsible_content && "relative max-h-64 overflow-hidden"
      ]}
    >
      <%= if is_binary(e2ee_payload) do %>
        <div data-role="e2ee-dm-body">{post_content_html(@entry.object)}</div>
      <% else %>
        {post_content_html(@entry.object)}
      <% end %>

      <div
        :if={is_binary(e2ee_payload)}
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
        :if={collapsible_content}
        id={fade_id}
        class="pointer-events-none absolute inset-x-0 bottom-0 h-20 bg-gradient-to-t from-[color:var(--bg-base)] to-transparent"
        aria-hidden="true"
      >
      </div>
    </div>

    <button
      :if={collapsible_content}
      type="button"
      data-role="post-content-toggle"
      aria-controls={content_id}
      aria-expanded="false"
      phx-click={
        JS.toggle_class("max-h-64 overflow-hidden", to: "##{content_id}")
        |> JS.toggle_class("hidden", to: "##{fade_id}")
        |> JS.toggle_class("hidden", to: "##{toggle_more_id}")
        |> JS.toggle_class("hidden", to: "##{toggle_less_id}")
        |> JS.toggle_class("rotate-180", to: "##{toggle_icon_id}")
        |> JS.toggle_attribute({"aria-expanded", "true", "false"})
      }
      class="mt-3 inline-flex items-center gap-2 border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--text-secondary)] transition hover:border-[color:var(--border-default)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal"
    >
      <span id={toggle_more_id}>Show more</span>
      <span id={toggle_less_id} class="hidden">Show less</span>
      <span id={toggle_icon_id} class="inline-flex">
        <.icon name="hero-chevron-down" class="size-4 transition" />
      </span>
    </button>

    <div
      :if={sensitive_media and @entry.attachments != []}
      id={"sensitive-media-#{@entry.object.id}"}
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
          JS.hide(to: "#sensitive-media-#{@entry.object.id}")
          |> JS.remove_class("hidden", to: "#attachments-#{@entry.object.id}")
        }
        class="inline-flex items-center gap-2 border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-4 py-2 text-sm font-bold uppercase text-[color:var(--bg-base)] transition hover:bg-[color:var(--accent-primary-hover)] focus-visible:outline-none focus-brutal"
      >
        <.icon name="hero-eye" class="size-4" /> Reveal
      </button>
    </div>

    <div
      :if={@entry.attachments != []}
      id={"attachments-#{@entry.object.id}"}
      data-role="attachments"
      data-layout={attachments_layout}
      class={[
        "mt-4 grid gap-3",
        attachments_layout == "grid" && "sm:grid-cols-2",
        sensitive_media && "hidden"
      ]}
    >
      <div :if={sensitive_media} class="col-span-full flex justify-end">
        <button
          type="button"
          data-role="sensitive-media-hide"
          phx-click={
            JS.show(to: "#sensitive-media-#{@entry.object.id}")
            |> JS.add_class("hidden", to: "#attachments-#{@entry.object.id}")
          }
          class="inline-flex items-center gap-2 border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] px-3 py-2 text-xs font-bold uppercase text-[color:var(--text-secondary)] transition hover:border-[color:var(--border-default)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal"
        >
          <.icon name="hero-eye-slash" class="size-4" />
          Hide media
        </button>
      </div>

      <div
        :for={{attachment, index} <- Enum.with_index(@entry.attachments)}
        class="group overflow-hidden border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)]"
      >
        <.attachment_media
          attachment={attachment}
          post_id={@entry.object.id}
          index={index}
          layout={attachments_layout}
        />
      </div>
    </div>
    """
  end

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

  defp sensitive_media?(%{data: %{} = data}) do
    data
    |> Map.get("sensitive", false)
    |> case do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp sensitive_media?(_object), do: false

  defp content_warning_text(%{data: %{} = data}) do
    case Map.get(data, "summary") do
      summary when is_binary(summary) ->
        summary = String.trim(summary)
        if summary == "", do: nil, else: summary

      _ ->
        nil
    end
  end

  defp content_warning_text(_object), do: nil

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

  defp avatar_initial(name) when is_binary(name) do
    name = String.trim(name)

    case String.first(name) do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end

  defp avatar_initial(_), do: "?"

  defp actor_profile_path(actor), do: ProfilePaths.profile_path(actor)

  defp with_back_timeline(path, nil) when is_binary(path), do: path

  defp with_back_timeline(path, back_timeline) when is_binary(path) do
    timeline =
      back_timeline
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if timeline in ["home", "public"] do
      delimiter = if String.contains?(path, "?"), do: "&", else: "?"
      path <> delimiter <> "back_timeline=" <> URI.encode_www_form(timeline)
    else
      path
    end
  end

  defp with_back_timeline(path, _back_timeline) when is_binary(path), do: path

  defp status_permalink_path(%{object: %{local: true} = object, actor: %{nickname: nickname}})
       when is_binary(nickname) and nickname != "" do
    case URL.local_object_uuid(Map.get(object, :ap_id)) do
      uuid when is_binary(uuid) and uuid != "" -> "/@#{nickname}/#{uuid}"
      _ -> nil
    end
  end

  defp status_permalink_path(%{object: %{id: id, local: false}, actor: actor})
       when is_integer(id) do
    case ProfilePaths.profile_path(actor) do
      "/@" <> _rest = profile_path -> profile_path <> "/" <> Integer.to_string(id)
      _ -> nil
    end
  end

  defp status_permalink_path(_entry), do: nil

  defp status_reply_path(entry) do
    case status_permalink_path(entry) do
      path when is_binary(path) and path != "" -> path <> "?reply=true#reply-form"
      _ -> nil
    end
  end

  defp status_share_url(entry) when is_map(entry) do
    object = Map.get(entry, :object) || %{}
    ap_id = Map.get(object, :ap_id) || Map.get(object, "ap_id")
    path = status_permalink_path(entry)

    cond do
      Map.get(object, :local) == true and is_binary(path) and path != "" ->
        URL.absolute(path)

      is_binary(ap_id) and ap_id != "" ->
        if safe_http_url?(ap_id), do: ap_id, else: nil

      true ->
        nil
    end
  end

  defp safe_http_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp safe_http_url?(_url), do: false

  attr :card_id, :string, required: true
  attr :entry, :map, required: true
  attr :current_user, :any, default: nil

  defp status_menu(assigns) do
    assigns =
      assigns
      |> assign(:share_url, status_share_url(assigns.entry))
      |> assign(:can_delete?, can_delete_post?(assigns.entry, assigns.current_user))
      |> assign(:bookmarked?, Map.get(assigns.entry, :bookmarked?, false))
      |> assign_new(:menu_id, fn -> "#{assigns.card_id}-menu" end)

    ~H"""
    <details id={@menu_id} data-role="status-menu" class="relative">
      <summary
        data-role="status-menu-trigger"
        aria-label="Post actions"
        class="list-none [&::-webkit-details-marker]:hidden"
      >
        <span class="inline-flex h-8 w-8 items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-subtle)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal">
          <.icon name="hero-ellipsis-horizontal" class="size-5" />
        </span>
      </summary>

      <div
        class="absolute right-0 top-9 z-40 w-48 overflow-hidden border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)]"
        phx-click-away={JS.remove_attribute("open", to: "##{@menu_id}")}
        phx-window-keydown={JS.remove_attribute("open", to: "##{@menu_id}")}
        phx-key="escape"
      >
        <button
          :if={is_binary(@share_url) and @share_url != ""}
          type="button"
          data-role="copy-link"
          data-copy-text={@share_url}
          phx-click={
            JS.dispatch("egregoros:copy")
            |> JS.push("copied_link")
            |> JS.remove_attribute("open", to: "##{@menu_id}")
          }
          class="flex w-full items-center gap-3 px-4 py-2.5 text-sm font-medium text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)]"
        >
          <.icon name="hero-clipboard-document" class="size-5 text-[color:var(--text-muted)]" />
          Copy link
        </button>

        <a
          :if={is_binary(@share_url) and @share_url != ""}
          data-role="open-link"
          href={@share_url}
          target="_blank"
          rel="nofollow noopener noreferrer"
          class="flex items-center gap-3 px-4 py-2.5 text-sm font-medium text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)]"
        >
          <.icon
            name="hero-arrow-top-right-on-square"
            class="size-5 text-[color:var(--text-muted)]"
          /> Open link
        </a>

        <button
          :if={@current_user}
          type="button"
          data-role="bookmark"
          phx-click="toggle_bookmark"
          phx-value-id={@entry.object.id}
          phx-disable-with="..."
          class={[
            "flex w-full items-center gap-3 px-4 py-2.5 text-sm font-medium transition hover:bg-[color:var(--bg-subtle)]",
            @bookmarked? && "text-[color:var(--text-primary)]",
            !@bookmarked? && "text-[color:var(--text-primary)]"
          ]}
        >
          <.icon
            name={if @bookmarked?, do: "hero-bookmark-solid", else: "hero-bookmark"}
            class={[
              "size-5",
              @bookmarked? && "text-[color:var(--text-primary)]",
              !@bookmarked? && "text-[color:var(--text-muted)]"
            ]}
          />
          {if @bookmarked?, do: "Unbookmark", else: "Bookmark"}
        </button>

        <%= if @can_delete? do %>
          <div class="border-t border-[color:var(--border-muted)]">
            <button
              type="button"
              data-role="delete-post"
              phx-click={JS.toggle(to: "#delete-post-confirm-#{@entry.object.id}")}
              class="flex w-full items-center gap-3 px-4 py-2.5 text-sm font-medium text-[color:var(--danger)] transition hover:bg-[color:var(--danger-subtle)]"
            >
              <.icon name="hero-trash" class="size-5" /> Delete post
            </button>

            <div
              id={"delete-post-confirm-#{@entry.object.id}"}
              class="hidden space-y-3 px-4 pb-4 pt-2 text-sm"
            >
              <p class="text-[color:var(--text-muted)]">
                This cannot be undone.
              </p>

              <div class="flex items-center justify-end gap-2">
                <button
                  type="button"
                  data-role="delete-post-cancel"
                  phx-click={JS.hide(to: "#delete-post-confirm-#{@entry.object.id}")}
                  class="inline-flex items-center justify-center border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
                >
                  Cancel
                </button>

                <button
                  type="button"
                  data-role="delete-post-confirm"
                  phx-click="delete_post"
                  phx-value-id={@entry.object.id}
                  phx-disable-with="Deleting..."
                  class="inline-flex items-center justify-center border-2 border-[color:var(--danger)] bg-[color:var(--danger)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--bg-base)] transition hover:bg-[color:var(--danger-subtle)] hover:text-[color:var(--danger)] focus-visible:outline-none focus-brutal"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </details>
    """
  end

  defp can_delete_post?(%{object: %{type: "Note", local: true, actor: actor}}, %User{ap_id: actor})
       when is_binary(actor) and actor != "" do
    true
  end

  defp can_delete_post?(_entry, _user), do: false

  attr :actor, :map, required: true

  defp actor_avatar(assigns) do
    ~H"""
    <%= if is_binary(@actor.avatar_url) and @actor.avatar_url != "" do %>
      <img
        src={@actor.avatar_url}
        alt={@actor.display_name}
        class="h-11 w-11 border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] object-cover"
        loading="lazy"
      />
    <% else %>
      <div class="flex h-11 w-11 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] font-bold text-[color:var(--text-secondary)]">
        {avatar_initial(@actor.display_name)}
      </div>
    <% end %>
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
    <%= case EgregorosWeb.Attachments.kind(@attachment) do %>
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
            src={@attachment.href}
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
              type={EgregorosWeb.Attachments.source_type(@attachment, "video/mp4")}
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
          >
            <source
              src={@attachment.href}
              type={EgregorosWeb.Attachments.source_type(@attachment, "audio/mpeg")}
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
