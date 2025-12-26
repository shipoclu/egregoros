defmodule Egregoros.Federation do
  alias Egregoros.Activities.Follow
  alias Egregoros.Federation.Actor
  alias Egregoros.Federation.WebFinger
  alias Egregoros.Pipeline
  alias Egregoros.User

  def follow_remote(%User{} = local_user, handle) when is_binary(handle) do
    with {:ok, actor_url} <- WebFinger.lookup(handle),
         {:ok, remote_user} <- Actor.fetch_and_store(actor_url),
         {:ok, _follow} <- Pipeline.ingest(Follow.build(local_user, remote_user), local: true) do
      {:ok, remote_user}
    end
  end
end
