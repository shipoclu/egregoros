defmodule Egregoros.Timeline do
  @moduledoc """
  Timeline feed backed by objects and PubSub broadcasts.
  """

  alias Egregoros.Objects

  @topic "timeline"

  def subscribe do
    Phoenix.PubSub.subscribe(Egregoros.PubSub, @topic)
  end

  def list_posts do
    Objects.list_notes()
  end

  def broadcast_post(object) do
    Phoenix.PubSub.broadcast(Egregoros.PubSub, @topic, {:post_created, object})
  end

  def reset do
    Objects.delete_all_notes()
  end
end
