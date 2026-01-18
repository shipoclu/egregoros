defmodule Egregoros.PublishPollCreationTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.Users

  describe "post_poll/4" do
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
  end
end
