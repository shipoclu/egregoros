defmodule EgregorosWeb.Components.TimelineItems.PollCard do
  @moduledoc """
  Component for rendering a Question (poll) in timelines.
  Displays poll options with vote counts and percentages.
  """
  use EgregorosWeb, :html

  alias EgregorosWeb.Components.Shared.ActorHeader
  alias EgregorosWeb.Components.Shared.ContentBody
  alias EgregorosWeb.Components.Shared.InteractionBar
  alias EgregorosWeb.Components.Shared.StatusMenu
  alias EgregorosWeb.ProfilePaths
  alias EgregorosWeb.URL

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :current_user, :any, default: nil
  attr :back_timeline, :any, default: nil
  attr :reply_mode, :atom, default: :navigate

  def poll_card(assigns) do
    ~H"""
    <article
      id={@id}
      data-role="status-card"
      data-type="Question"
      class="scroll-mt-24 border-b border-[color:var(--border-muted)] bg-[color:var(--bg-base)] p-5 transition hover:bg-[color:var(--bg-subtle)] target:ring-2 target:ring-[color:var(--border-default)]"
    >
      <div class="flex items-start justify-between gap-3">
        <ActorHeader.actor_header
          actor={@entry.actor}
          object={@entry.object}
        />

        <div class="flex items-center gap-2">
          <.permalink_timestamp
            entry={@entry}
            back_timeline={@back_timeline}
          />

          <StatusMenu.status_menu
            card_id={@id}
            entry={@entry}
            current_user={@current_user}
          />
        </div>
      </div>

      <ContentBody.content_body
        id={@id}
        object={@entry.object}
        current_user={@current_user}
      />

      <.poll_results
        poll={@entry.poll}
        current_user={@current_user}
      />

      <InteractionBar.interaction_bar
        id={@id}
        entry={@entry}
        current_user={@current_user}
        reply_mode={@reply_mode}
      />
    </article>
    """
  end

  attr :poll, :map, required: true
  attr :current_user, :any, default: nil

  defp poll_results(assigns) do
    assigns = assign_new(assigns, :show_results?, fn ->
      poll = assigns.poll
      poll.own_poll? or poll.voted? or poll.expired?
    end)

    ~H"""
    <div class="mt-4 space-y-2" data-role="poll-results">
      <div class="mb-3 flex items-center gap-2">
        <.icon name="hero-chart-bar" class="size-4 text-[color:var(--text-muted)]" />
        <span class="text-xs font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
          Poll {if @poll.multiple?, do: "(multiple choice)", else: "(single choice)"}
        </span>
      </div>

      <%= if @show_results? do %>
        <.poll_option_result
          :for={option <- @poll.options}
          option={option}
          total_votes={@poll.total_votes}
        />
      <% else %>
        <.poll_option_stub :for={option <- @poll.options} option={option} />
      <% end %>

      <.poll_footer poll={@poll} />
    </div>
    """
  end

  attr :option, :map, required: true
  attr :total_votes, :integer, required: true

  defp poll_option_result(assigns) do
    percentage =
      if assigns.total_votes > 0 do
        Float.round(assigns.option.votes / assigns.total_votes * 100, 1)
      else
        0.0
      end

    assigns = assign(assigns, :percentage, percentage)

    ~H"""
    <div class="relative overflow-hidden border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)]">
      <div
        class="absolute inset-y-0 left-0 bg-[color:var(--bg-subtle)]"
        style={"width: #{@percentage}%"}
      />
      <div class="relative flex items-center justify-between gap-4 px-4 py-3">
        <span class="min-w-0 truncate font-medium text-[color:var(--text-primary)]">
          {@option.name}
        </span>
        <div class="flex shrink-0 items-center gap-3">
          <span class="font-mono text-sm text-[color:var(--text-muted)]">
            {format_votes(@option.votes)}
          </span>
          <span class="w-12 text-right font-mono text-sm font-bold text-[color:var(--text-secondary)]">
            {format_percentage(@percentage)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :option, :map, required: true

  defp poll_option_stub(assigns) do
    ~H"""
    <div class="border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-4 py-3 text-[color:var(--text-secondary)] opacity-75">
      <span class="truncate">{@option.name}</span>
      <span class="ml-2 text-xs text-[color:var(--text-muted)]">(voting coming soon)</span>
    </div>
    """
  end

  attr :poll, :map, required: true

  defp poll_footer(assigns) do
    ~H"""
    <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-[color:var(--text-muted)]">
      <span>{format_total_votes(@poll.total_votes)} · {format_voters(@poll.voters_count)}</span>

      <%= if @poll.expired? do %>
        <span class="font-bold text-[color:var(--warning)]">Poll ended</span>
      <% else %>
        <%= if @poll.closed do %>
          <span>Ends {format_datetime(@poll.closed)}</span>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :back_timeline, :any, default: nil

  defp permalink_timestamp(assigns) do
    ~H"""
    <%= if is_binary(permalink_path = status_permalink_path(@entry)) do %>
      <.link
        navigate={with_back_timeline(permalink_path, @back_timeline)}
        data-role="post-permalink"
        class="inline-flex hover:underline underline-offset-2 focus-visible:outline-none focus-brutal"
        aria-label="Open post"
      >
        <.time_ago at={object_timestamp(@entry.object)} />
      </.link>
    <% else %>
      <.time_ago at={object_timestamp(@entry.object)} />
    <% end %>
    """
  end

  # Helper functions

  defp format_votes(1), do: "1 vote"
  defp format_votes(n) when is_integer(n), do: "#{n} votes"
  defp format_votes(_), do: "0 votes"

  defp format_total_votes(1), do: "1 vote total"
  defp format_total_votes(n) when is_integer(n), do: "#{n} votes total"
  defp format_total_votes(_), do: "0 votes total"

  defp format_voters(1), do: "1 voter"
  defp format_voters(n) when is_integer(n), do: "#{n} voters"
  defp format_voters(_), do: "0 voters"

  defp format_percentage(p) when is_float(p), do: "#{p}%"
  defp format_percentage(_), do: "0%"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end

  defp format_datetime(_), do: ""

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

  defp object_timestamp(%{published: %DateTime{} = dt}), do: dt
  defp object_timestamp(%{published: %NaiveDateTime{} = dt}), do: dt

  defp object_timestamp(%{data: %{"published" => published}}) when is_binary(published) do
    case DateTime.from_iso8601(published) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp object_timestamp(%{inserted_at: %DateTime{} = dt}), do: dt
  defp object_timestamp(%{inserted_at: %NaiveDateTime{} = dt}), do: dt
  defp object_timestamp(_), do: nil
end
