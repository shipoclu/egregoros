defmodule Egregoros.Workers.RefreshRemoteFollowingGraphsDaily do
  use Oban.Worker,
    queue: :federation_incoming,
    max_attempts: 1,
    unique: [period: 60 * 60 * 23]

  import Ecto.Query, only: [from: 2]

  alias Egregoros.Relationship
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Workers.RefreshRemoteFollowingGraph

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    jobs =
      remote_followed_ap_ids()
      |> Enum.map(fn ap_id ->
        RefreshRemoteFollowingGraph.new(%{"ap_id" => ap_id}, priority: 9)
      end)

    if jobs != [] do
      _ = Oban.insert_all(jobs)
    end

    :ok
  end

  defp remote_followed_ap_ids do
    from(r in Relationship,
      join: actor in User,
      on: actor.ap_id == r.actor,
      join: object in User,
      on: object.ap_id == r.object,
      where: r.type == "Follow",
      where: actor.local == true,
      where: object.local == false,
      distinct: true,
      select: object.ap_id
    )
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
