defmodule PleromaRedux.Timeline do
  @moduledoc """
  Timeline feed backed by objects and PubSub broadcasts.
  """

  alias PleromaRedux.Objects

  @topic "timeline"

  def subscribe do
    Phoenix.PubSub.subscribe(PleromaRedux.PubSub, @topic)
  end

  def list_posts do
    Objects.list_notes()
  end

  def broadcast_post(object) do
    Phoenix.PubSub.broadcast(PleromaRedux.PubSub, @topic, {:post_created, object})
  end

  def reset do
    Objects.delete_all_notes()
  end
end
