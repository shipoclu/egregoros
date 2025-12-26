defmodule Egregoros.Bench.SeedTest do
  use Egregoros.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Egregoros.Bench.Seed
  alias Egregoros.Object
  alias Egregoros.Relationship
  alias Egregoros.Repo
  alias Egregoros.User

  test "seed!/1 inserts a realistic dataset and returns counts" do
    summary =
      Seed.seed!(
        local_users: 2,
        remote_users: 3,
        days: 2,
        posts_per_day: 5,
        follows_per_user: 2,
        seed: 123,
        reset?: false
      )

    assert %{
             users: %{local: 2, remote: 3},
             objects: %{notes: 10},
             relationships: %{follows: 4}
           } = summary

    assert Repo.aggregate(User, :count, :id) == 5

    assert Repo.aggregate(from(o in Object, where: o.type == "Note"), :count, :id) == 10

    assert Repo.aggregate(from(r in Relationship, where: r.type == "Follow"), :count, :id) == 4
  end

  test "seed!/1 handles zero counts without crashing" do
    summary =
      Seed.seed!(
        local_users: 0,
        remote_users: 0,
        days: 0,
        posts_per_day: 0,
        follows_per_user: 0,
        seed: 123,
        reset?: false
      )

    assert %{users: %{local: 0, remote: 0}, objects: %{notes: 0}, relationships: %{follows: 0}} =
             summary

    assert Repo.aggregate(User, :count, :id) == 0
    assert Repo.aggregate(from(o in Object, where: o.type == "Note"), :count, :id) == 0
    assert Repo.aggregate(from(r in Relationship, where: r.type == "Follow"), :count, :id) == 0
  end
end
