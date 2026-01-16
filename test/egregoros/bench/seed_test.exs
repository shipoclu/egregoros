defmodule Egregoros.Bench.SeedTest do
  use Egregoros.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Egregoros.Bench.Seed
  alias Egregoros.Object
  alias Egregoros.Repo

  test "seed!/1 works with remote_users=0" do
    summary =
      Seed.seed!(
        local_users: 2,
        remote_users: 0,
        days: 1,
        posts_per_day: 5,
        follows_per_user: 0,
        reset?: true,
        seed: 123
      )

    assert summary.users.local == 4
    assert summary.users.remote == 0
    assert summary.objects.notes == 5
    assert summary.relationships.follows == 0

    notes =
      from(o in Object, where: o.type == "Note")
      |> Repo.all()

    assert Enum.all?(notes, fn note ->
             tags = note.data |> Map.get("tag", []) |> List.wrap()

             Enum.any?(tags, fn
               %{"type" => "Hashtag", "name" => "#bench"} -> true
               _ -> false
             end)
           end)

    assert Enum.any?(notes, &(&1.has_media == true))

    assert Enum.all?(notes, fn note ->
             if note.has_media == true do
               attachments = note.data |> Map.get("attachment") |> List.wrap()
               is_list(attachments) and attachments != []
             else
               true
             end
           end)
  end

  test "seed!/1 chunks insert_all to stay under Postgres parameter limits" do
    # Inserting too many rows in one insert_all would exceed Postgres' 65_535 parameter limit.
    # This ensures we keep chunking logic in place.
    notes = 7_400

    summary =
      Seed.seed!(
        local_users: 1,
        remote_users: 0,
        days: 1,
        posts_per_day: notes,
        follows_per_user: 0,
        reset?: true,
        seed: 123
      )

    assert summary.objects.notes == notes
  end

  test "seed!/1 supports follow relationship seeding" do
    summary =
      Seed.seed!(
        local_users: 1,
        remote_users: 10,
        days: 1,
        posts_per_day: 1,
        follows_per_user: 5,
        reset?: true,
        seed: 123
      )

    assert summary.users.local == 3
    assert summary.users.remote == 10
    assert summary.objects.notes == 1
    assert summary.relationships.follows > 0
  end
end
