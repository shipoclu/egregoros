defmodule EgregorosWeb.Components.TimelineItems.AnnounceCard do
  @moduledoc """
  Component for rendering an Announce (repost/boost) in timelines.

  An Announce wraps another object (typically a Note) and displays it
  with attribution to the user who reposted it. The actual content
  rendering is delegated to NoteCard.
  """
  use EgregorosWeb, :html

  alias EgregorosWeb.Components.TimelineItems.NoteCard

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :current_user, :any, default: nil
  attr :back_timeline, :any, default: nil
  attr :reply_mode, :atom, default: :navigate

  @doc """
  Renders an Announce (repost/boost).

  The entry should already be decorated by the StatusVM, which resolves
  the Announce to the underlying Note and adds a :reposted_by field
  with the actor who performed the repost.
  """
  def announce_card(assigns) do
    # An Announce is rendered as a NoteCard with the reposted_by header shown
    # The StatusVM.decorate/2 function already resolves the Announce to its
    # underlying Note and adds the :reposted_by field
    ~H"""
    <NoteCard.note_card
      id={@id}
      entry={@entry}
      current_user={@current_user}
      back_timeline={@back_timeline}
      reply_mode={@reply_mode}
      show_reposted_by={true}
    />
    """
  end
end
