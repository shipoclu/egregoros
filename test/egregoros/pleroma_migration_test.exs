defmodule Egregoros.PleromaMigrationTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.PleromaMigration
  alias Egregoros.Repo
  alias Egregoros.User

  test "import_users/1 inserts users and returns a summary" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    nickname = "alice#{System.unique_integer([:positive])}"
    ap_id = "https://example.com/users/#{nickname}"

    users = [
      %{
        id: FlakeId.get(),
        nickname: nickname,
        domain: nil,
        ap_id: ap_id,
        inbox: ap_id <> "/inbox",
        outbox: ap_id <> "/outbox",
        public_key: "PUB",
        private_key: "PRIV",
        local: true,
        inserted_at: now,
        updated_at: now
      }
    ]

    assert %{inserted: 1, attempted: 1} = PleromaMigration.import_users(users)

    assert %User{nickname: ^nickname} = Repo.get_by(User, nickname: nickname, local: true)
  end
end
