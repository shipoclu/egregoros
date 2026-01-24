defmodule Egregoros.PublishPollCreationTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.Publish.Polls, as: PublishPolls
  alias Egregoros.Users
  alias Egregoros.Workers.ResolveMentions

  describe "post_poll/4" do
    test "returns :invalid_poll for unexpected args" do
      assert {:error, :invalid_poll} = PublishPolls.post_poll(:not_a_user, "", %{}, [])
    end

    test "creates a Question with poll options" do
      {:ok, author} = Users.create_local_user("poll_author")

      assert {:ok, create} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["Red", "Blue"],
                 "multiple" => false,
                 "expires_in" => 3600
               })

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert question.actor == author.ap_id
      assert is_binary(question.data["closed"])

      assert Enum.map(question.data["oneOf"], & &1["name"]) == ["Red", "Blue"]
      refute Map.has_key?(question.data, "anyOf")
    end

    test "rejects blank or duplicate options" do
      {:ok, author} = Users.create_local_user("poll_author_invalid")

      assert {:error, "Poll options must be unique."} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["Yes", "Yes"],
                 "multiple" => false,
                 "expires_in" => 3600
               })

      assert {:error, "Poll options cannot be blank."} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["", "No"],
                 "multiple" => false,
                 "expires_in" => 3600
               })
    end

    test "rejects empty content and content over the length limit" do
      {:ok, author} = Users.create_local_user("poll_author_content_limits")

      assert {:error, :empty} =
               Publish.post_poll(author, "   ", %{
                 "options" => ["Red", "Blue"],
                 "multiple" => false,
                 "expires_in" => 3600
               })

      too_long = String.duplicate("a", 5001)

      assert {:error, :too_long} =
               Publish.post_poll(author, too_long, %{
                 "options" => ["Red", "Blue"],
                 "multiple" => false,
                 "expires_in" => 3600
               })
    end

    test "rejects expiration dates that are too soon or too far" do
      {:ok, author} = Users.create_local_user("poll_author_expiration_limits")

      assert {:error, "Expiration date is too soon"} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["Red", "Blue"],
                 "multiple" => false,
                 "expires_in" => 60
               })

      assert {:error, "Expiration date is too far in the future"} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["Red", "Blue"],
                 "multiple" => false,
                 "expires_in" => 3_000_000
               })
    end

    test "creates an anyOf Question when multiple choices are enabled" do
      {:ok, author} = Users.create_local_user("poll_author_multiple")

      assert {:ok, create} =
               Publish.post_poll(author, "Pick multiple", %{
                 "options" => ["Red", "Blue"],
                 "multiple" => true,
                 "expires_in" => 3600
               })

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert Enum.map(question.data["anyOf"], & &1["name"]) == ["Red", "Blue"]
      refute Map.has_key?(question.data, "oneOf")
    end

    test "direct polls include mention and hashtag tags" do
      {:ok, author} = Users.create_local_user("poll_author_direct")
      {:ok, recipient} = Users.create_local_user("poll_direct_recipient")

      assert {:ok, create} =
               Publish.post_poll(
                 author,
                 "Pick one @poll_direct_recipient #colors",
                 %{
                   "options" => ["Red", "Blue"],
                   "multiple" => false,
                   "expires_in" => 3600
                 },
                 visibility: "direct"
               )

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert question.data["to"] == [recipient.ap_id]
      assert question.data["cc"] == []

      assert Enum.any?(question.data["tag"], fn tag ->
               tag["type"] == "Mention" and tag["href"] == recipient.ap_id
             end)

      assert Enum.any?(question.data["tag"], fn tag ->
               tag["type"] == "Hashtag" and tag["name"] == "#colors"
             end)
    end

    test "supports spoiler_text, sensitive, and language opts" do
      {:ok, author} = Users.create_local_user("poll_author_opts")

      assert {:ok, create} =
               Publish.post_poll(
                 author,
                 "Pick one",
                 %{
                   "options" => ["Red", "Blue"],
                   "multiple" => false,
                   "expires_in" => 3600
                 },
                 spoiler_text: "CW",
                 sensitive: true,
                 language: "en"
               )

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert question.data["summary"] == "CW"
      assert question.data["sensitive"] == true
      assert question.data["language"] == "en"
    end

    test "coerces expires_in from a string and multiple from truthy values" do
      {:ok, author} = Users.create_local_user("poll_author_coercions")

      assert {:ok, create} =
               Publish.post_poll(author, "Pick multiple", %{
                 "options" => ["Red", "Blue"],
                 "multiple" => "1",
                 "expires_in" => "3600"
               })

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert Enum.map(question.data["anyOf"], & &1["name"]) == ["Red", "Blue"]
    end

    test "treats sensitive string values as true" do
      {:ok, author} = Users.create_local_user("poll_author_sensitive_string")

      assert {:ok, create} =
               Publish.post_poll(
                 author,
                 "Pick one",
                 %{
                   "options" => ["Red", "Blue"],
                   "multiple" => "true",
                   "expires_in" => 3600
                 },
                 sensitive: "true"
               )

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert question.data["sensitive"] == true
    end

    test "rejects non-integer expires_in types" do
      {:ok, author} = Users.create_local_user("poll_author_expires_in_type")

      assert {:error, "Invalid poll"} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["Red", "Blue"],
                 "multiple" => false,
                 "expires_in" => :bad
               })
    end

    test "allows polls with attachments even when content is blank" do
      {:ok, author} = Users.create_local_user("poll_author_attachments")

      attachments = [
        %{
          "type" => "Document",
          "mediaType" => "image/png",
          "url" => [
            %{"type" => "Link", "href" => "https://example.com/uploads/poll.png"}
          ]
        }
      ]

      assert {:ok, create} =
               Publish.post_poll(
                 author,
                 "",
                 %{
                   "options" => ["Red", "Blue"],
                   "multiple" => false,
                   "expires_in" => 3600
                 },
                 attachments: attachments
               )

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert question.data["attachment"] == attachments
    end

    test "private polls are addressed to followers" do
      {:ok, author} = Users.create_local_user("poll_author_private_visibility")

      assert {:ok, create} =
               Publish.post_poll(
                 author,
                 "Pick one",
                 %{
                   "options" => ["Red", "Blue"],
                   "multiple" => false,
                   "expires_in" => 3600
                 },
                 visibility: "private"
               )

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert question.data["to"] == [author.ap_id <> "/followers"]
      assert question.data["cc"] == []
      refute "https://www.w3.org/ns/activitystreams#Public" in question.data["to"]
      refute "https://www.w3.org/ns/activitystreams#Public" in question.data["cc"]
    end

    test "rejects polls with too few options" do
      {:ok, author} = Users.create_local_user("poll_author_too_few")

      assert {:error, "Poll must contain at least 2 options"} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["Only one"],
                 "multiple" => false,
                 "expires_in" => 3600
               })
    end

    test "rejects polls with invalid expires_in" do
      {:ok, author} = Users.create_local_user("poll_author_invalid_expires")

      assert {:error, "Invalid poll"} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["Red", "Blue"],
                 "multiple" => false,
                 "expires_in" => "nope"
               })
    end

    test "rejects too many options and overly long option text" do
      {:ok, author} = Users.create_local_user("poll_author_option_limits")

      assert {:error, "Poll can't contain more than 4 options"} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => ["a", "b", "c", "d", "e"],
                 "multiple" => false,
                 "expires_in" => 3600
               })

      long_option = String.duplicate("a", 51)

      assert {:error, "Poll options cannot be longer than 50 characters each"} =
               Publish.post_poll(author, "Pick one", %{
                 "options" => [long_option, "b"],
                 "multiple" => false,
                 "expires_in" => 3600
               })
    end

    test "unresolved remote mentions enqueue a ResolveMentions job" do
      {:ok, author} = Users.create_local_user("poll_author_remote_mentions")

      assert {:ok, create} =
               Publish.post_poll(
                 author,
                 "Pick one @someone@remote.example",
                 %{
                   "options" => ["Red", "Blue"],
                   "multiple" => false,
                   "expires_in" => 3600
                 },
                 visibility: "public"
               )

      assert_enqueued(
        worker: ResolveMentions,
        args: %{
          "create_ap_id" => create.ap_id,
          "remote_mentions" => ["someone@remote.example"]
        }
      )
    end

    test "unlisted polls are addressed to followers" do
      {:ok, author} = Users.create_local_user("poll_author_unlisted")

      assert {:ok, create} =
               Publish.post_poll(
                 author,
                 "Pick one",
                 %{
                   "options" => ["Red", "Blue"],
                   "multiple" => false,
                   "expires_in" => 3600
                 },
                 visibility: "unlisted"
               )

      question = Objects.get_by_ap_id(create.object)
      assert question.type == "Question"
      assert question.data["to"] == [author.ap_id <> "/followers"]

      assert "https://www.w3.org/ns/activitystreams#Public" in question.data["cc"]
    end

    test "poll replies mention the parent author" do
      {:ok, parent_author} = Users.create_local_user("poll_reply_parent")
      {:ok, author} = Users.create_local_user("poll_reply_author")

      assert {:ok, parent_create} = Publish.post_note(parent_author, "Parent")
      parent_note_ap_id = parent_create.object

      assert {:ok, create} =
               Publish.post_poll(
                 author,
                 "Reply poll",
                 %{
                   "options" => ["Red", "Blue"],
                   "multiple" => false,
                   "expires_in" => 3600
                 },
                 in_reply_to: parent_note_ap_id
               )

      question = Objects.get_by_ap_id(create.object)

      assert Enum.any?(question.data["tag"], fn tag ->
               tag["type"] == "Mention" and tag["href"] == parent_author.ap_id
             end)
    end
  end
end
