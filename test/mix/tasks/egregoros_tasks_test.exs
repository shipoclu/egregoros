defmodule Egregoros.MixTasksTest do
  use Egregoros.DataCase, async: false

  import ExUnit.CaptureIO

  alias Egregoros.Users

  describe "mix egregoros.admin" do
    test "promotes and demotes local users" do
      {:ok, user} = Users.create_local_user("alice")
      assert user.admin == false

      output =
        capture_io(fn ->
          Mix.Tasks.Egregoros.Admin.run(["promote", "alice"])
        end)

      assert output =~ "promoted"
      assert Users.get(user.id).admin == true

      output =
        capture_io(fn ->
          Mix.Tasks.Egregoros.Admin.run(["demote", "alice"])
        end)

      assert output =~ "demoted"
      assert Users.get(user.id).admin == false
    end

    test "raises on invalid arguments" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Egregoros.Admin.run(["nope"])
      end
    end

    test "raises when the user does not exist" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Egregoros.Admin.run(["promote", "missing"])
      end
    end
  end

  describe "mix egregoros.actors.refetch" do
    test "dry-run reports how many actors would be refetched" do
      {:ok, _remote} =
        Users.create_user(%{
          nickname: "bob",
          domain: "remote.example",
          ap_id: "https://remote.example/users/bob",
          inbox: "https://remote.example/users/bob/inbox",
          outbox: "https://remote.example/users/bob/outbox",
          public_key: "remote-key",
          private_key: nil,
          local: false
        })

      output =
        capture_io(fn ->
          Mix.Tasks.Egregoros.Actors.Refetch.run(["--all", "--dry-run"])
        end)

      assert output =~ "would refetch"
    end

    test "raises on invalid options" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Egregoros.Actors.Refetch.run(["--limit", "nope"])
      end
    end
  end

  describe "mix egregoros.bench.seed" do
    test "refuses to reset without --force" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Egregoros.Bench.Seed.run([])
      end
    end
  end

  describe "mix egregoros.bench.run" do
    test "runs a filtered benchmark suite" do
      output =
        capture_io(fn ->
          Mix.Tasks.Egregoros.Bench.Run.run([
            "--warmup",
            "0",
            "--iterations",
            "1",
            "--filter",
            "timeline.public"
          ])
        end)

      assert output =~ "Benchmark: warmup=0 iterations=1"
      assert output =~ "timeline.public.list_notes"
    end
  end

  describe "mix egregoros.bench.explain" do
    test "prints explain output for a filtered case" do
      output =
        capture_io(fn ->
          Mix.Tasks.Egregoros.Bench.Explain.run([
            "--filter",
            "timeline.public.list_notes"
          ])
        end)

      assert output =~ "timeline.public.list_notes"
      assert output =~ "EXPLAIN"
    end
  end

  describe "mix egregoros.import_pleroma" do
    test "imports users and statuses from a source and prints a summary" do
      alias Egregoros.PleromaMigration.Source

      previous_source = Application.get_env(:egregoros, Source)
      Application.put_env(:egregoros, Source, Source.Mock)

      on_exit(fn ->
        if is_nil(previous_source) do
          Application.delete_env(:egregoros, Source)
        else
          Application.put_env(:egregoros, Source, previous_source)
        end
      end)

      Source.Mock
      |> expect(:list_users, fn opts ->
        assert opts[:url] == "postgres://example"
        {:ok, []}
      end)
      |> expect(:list_statuses, fn _opts -> {:ok, []} end)

      output =
        capture_io(fn ->
          Mix.Tasks.Egregoros.ImportPleroma.run(["--url", "postgres://example"])
        end)

      assert output =~ "Imported users: 0/0"
      assert output =~ "Imported statuses: 0/0"
    end
  end
end
