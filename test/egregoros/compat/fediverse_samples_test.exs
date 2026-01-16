defmodule Egregoros.Compat.FediverseSamplesTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.HTML
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.TestSupport.Fixtures

  describe "fedifun.dev/fediverse-samples fixtures" do
    test "ingests a Create activity with required fields" do
      activity = Fixtures.json!("fediverse_samples/activity/necessary_properties_0.json")

      assert {:ok, create} = Pipeline.ingest(activity, local: false)
      assert create.type == "Create"
      assert create.actor == activity["actor"]

      note = Objects.get_by_ap_id(activity["object"]["id"])
      assert %{} = note
      assert note.type == "Note"
      assert is_binary(note.data["content"])
    end

    test "rejects Create activities with invalid embedded objects" do
      missing_id = Fixtures.json!("fediverse_samples/activity/necessary_properties_1.json")
      missing_type = Fixtures.json!("fediverse_samples/activity/necessary_properties_4.json")

      assert {:error, :invalid} = Pipeline.ingest(missing_id, local: false)
      assert {:error, :invalid} = Pipeline.ingest(missing_type, local: false)
    end

    test "normalizes Hashtag tag names (leading #, downcased)" do
      activity = Fixtures.json!("fediverse_samples/activity/hashtags_1.json")

      assert {:ok, _create} = Pipeline.ingest(activity, local: false)

      note = Objects.get_by_ap_id(activity["object"]["id"])
      assert %{} = note

      tags = note.data["tag"] |> List.wrap()

      assert Enum.any?(tags, fn tag ->
               is_map(tag) and tag["type"] == "Hashtag" and tag["name"] == "#nohash"
             end)
    end

    test "accepts tag as a single map (not a list)" do
      activity = Fixtures.json!("fediverse_samples/activity/hashtags_14.json")

      assert {:ok, _create} = Pipeline.ingest(activity, local: false)

      note = Objects.get_by_ap_id(activity["object"]["id"])
      assert %{} = note
      assert [%{"type" => "Hashtag", "name" => "#test"}] = note.data["tag"]
    end

    test "accepts Emoji tags" do
      activity = Fixtures.json!("fediverse_samples/activity/emoji_0.json")

      assert {:ok, _create} = Pipeline.ingest(activity, local: false)

      note = Objects.get_by_ap_id(activity["object"]["id"])
      assert %{} = note

      tags = note.data["tag"] |> List.wrap()

      assert Enum.any?(tags, fn tag ->
               is_map(tag) and tag["type"] == "Emoji" and tag["name"] == ":cow1:"
             end)
    end

    test "accepts attachments" do
      activity = Fixtures.json!("fediverse_samples/activity/attachments_0.json")

      assert {:ok, _create} = Pipeline.ingest(activity, local: false)

      note = Objects.get_by_ap_id(activity["object"]["id"])
      assert %{} = note

      assert [
               %{
                 "type" => "Image",
                 "mediaType" => "image/jpeg",
                 "url" => "http://pasture-one-actor/assets/cow.jpg"
               } = _attachment
             ] = note.data["attachment"]
    end

    test "sanitizes disallowed HTML tags at render time" do
      activity = Fixtures.json!("fediverse_samples/activity/html_bad_0.json")

      assert {:ok, _create} = Pipeline.ingest(activity, local: false)

      note = Objects.get_by_ap_id(activity["object"]["id"])
      assert %{} = note

      rendered = HTML.to_safe_html(note.data["content"])

      refute rendered =~ "<body"
      assert rendered =~ "body"
    end
  end
end
