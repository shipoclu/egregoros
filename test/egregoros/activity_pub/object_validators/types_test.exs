defmodule Egregoros.ActivityPub.ObjectValidators.TypesTest do
  use ExUnit.Case, async: true

  alias Egregoros.ActivityPub.ObjectValidators.Types.ObjectID
  alias Egregoros.ActivityPub.ObjectValidators.Types.Recipients
  alias Egregoros.ActivityPub.ObjectValidators.Types.DateTime, as: APDateTime

  describe "ObjectID" do
    test "declares its ecto type" do
      assert ObjectID.type() == :string
    end

    test "casts a non-empty string" do
      assert {:ok, "https://example.com/objects/1"} =
               Ecto.Type.cast(ObjectID, "https://example.com/objects/1")
    end

    test "trims whitespace" do
      assert {:ok, "https://example.com/objects/1"} =
               Ecto.Type.cast(ObjectID, "  https://example.com/objects/1  ")
    end

    test "casts a map with an id" do
      assert {:ok, "https://example.com/objects/1"} =
               Ecto.Type.cast(ObjectID, %{"id" => "https://example.com/objects/1"})
    end

    test "casts a nested id map" do
      assert {:ok, "https://example.com/objects/1"} =
               Ecto.Type.cast(ObjectID, %{"id" => %{"id" => "https://example.com/objects/1"}})
    end

    test "casts a struct with an id field" do
      assert {:ok, "https://example.com/objects/1"} =
               Ecto.Type.cast(ObjectID, %{id: "https://example.com/objects/1"})
    end

    test "rejects empty strings" do
      assert :error = Ecto.Type.cast(ObjectID, "   ")
    end

    test "rejects non-binary values" do
      assert {:ok, nil} = Ecto.Type.cast(ObjectID, nil)
      assert :error = Ecto.Type.cast(ObjectID, %{})
      assert :error = Ecto.Type.cast(ObjectID, 123)
    end

    test "rejects nil via direct cast" do
      assert :error == ObjectID.cast(nil)
    end

    test "dump/load are passthrough" do
      assert {:ok, "https://example.com/objects/1"} =
               ObjectID.dump("https://example.com/objects/1")

      assert {:ok, "https://example.com/objects/1"} =
               ObjectID.load("https://example.com/objects/1")
    end
  end

  describe "Recipients" do
    test "declares its ecto type" do
      assert Recipients.type() == {:array, ObjectID}
    end

    test "casts a string into a singleton list" do
      assert {:ok, ["https://example.com/users/alice"]} =
               Ecto.Type.cast(Recipients, "https://example.com/users/alice")
    end

    test "casts a map into a singleton list" do
      assert {:ok, ["https://example.com/users/alice"]} =
               Ecto.Type.cast(Recipients, %{"id" => "https://example.com/users/alice"})
    end

    test "casts a list and drops invalid entries" do
      assert {:ok, ["https://example.com/users/alice", "https://example.com/users/bob"]} =
               Ecto.Type.cast(Recipients, [
                 "https://example.com/users/bob",
                 "   ",
                 %{},
                 %{"id" => "https://example.com/users/alice"}
               ])
    end

    test "returns nil for nil" do
      assert {:ok, nil} = Ecto.Type.cast(Recipients, nil)
    end

    test "rejects invalid maps" do
      assert :error = Ecto.Type.cast(Recipients, %{})
      assert :error = Ecto.Type.cast(Recipients, %{"id" => "   "})
    end

    test "rejects invalid values via direct cast" do
      assert :error == Recipients.cast(123)
    end

    test "sorts and deduplicates recipients" do
      assert {:ok, ["https://example.com/users/alice", "https://example.com/users/bob"]} =
               Ecto.Type.cast(Recipients, [
                 "https://example.com/users/bob",
                 "https://example.com/users/alice",
                 "https://example.com/users/bob"
               ])
    end

    test "dump/load are passthrough" do
      assert {:ok, ["https://example.com/users/alice"]} =
               Recipients.dump(["https://example.com/users/alice"])

      assert {:ok, ["https://example.com/users/alice"]} =
               Recipients.load(["https://example.com/users/alice"])
    end
  end

  describe "DateTime" do
    test "declares its ecto type" do
      assert APDateTime.type() == :string
    end

    test "casts iso8601 values" do
      assert {:ok, "2020-01-01T00:00:00Z"} = Ecto.Type.cast(APDateTime, "2020-01-01T00:00:00Z")
    end

    test "treats missing offsets as UTC" do
      assert {:ok, "2020-01-01T00:00:00Z"} = Ecto.Type.cast(APDateTime, "2020-01-01T00:00:00")
    end

    test "rejects invalid values" do
      assert :error = Ecto.Type.cast(APDateTime, "nope")
    end

    test "rejects non-binary values" do
      assert {:ok, nil} = Ecto.Type.cast(APDateTime, nil)
      assert :error = Ecto.Type.cast(APDateTime, 123)
    end

    test "rejects nil via direct cast" do
      assert :error == APDateTime.cast(nil)
    end

    test "dump/load are passthrough" do
      assert {:ok, "2020-01-01T00:00:00Z"} = APDateTime.dump("2020-01-01T00:00:00Z")
      assert {:ok, "2020-01-01T00:00:00Z"} = APDateTime.load("2020-01-01T00:00:00Z")
    end
  end
end
