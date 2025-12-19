defmodule PleromaRedux.Timeline do
  @moduledoc """
  In-memory timeline store for the initial live-update slice.
  """

  use Agent

  alias __MODULE__.Post

  @topic "timeline"

  defmodule Post do
    @enforce_keys [:id, :content, :inserted_at]
    defstruct [:id, :content, :inserted_at]
  end

  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(PleromaRedux.PubSub, @topic)
  end

  def list_posts do
    Agent.get(__MODULE__, & &1)
  end

  def create_post(content) when is_binary(content) do
    content = String.trim(content)

    if content == "" do
      {:error, :empty}
    else
      post = %Post{
        id: System.unique_integer([:positive, :monotonic]),
        content: content,
        inserted_at: DateTime.utc_now()
      }

      Agent.update(__MODULE__, fn posts -> [post | posts] end)
      Phoenix.PubSub.broadcast(PleromaRedux.PubSub, @topic, {:post_created, post})
      {:ok, post}
    end
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end
