defmodule Egregoros.Activities.QuestionBuildTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Question
  alias Egregoros.User
  alias EgregorosWeb.Endpoint

  test "build/3 returns a basic Question object" do
    actor_ap_id = Endpoint.url() <> "/users/alice"
    user = %User{ap_id: actor_ap_id}

    question = Question.build(user, "hello", "<p>hello</p>")

    assert question["type"] == "Question"
    assert question["actor"] == actor_ap_id
    assert question["attributedTo"] == actor_ap_id
    assert is_binary(question["id"])
    assert String.starts_with?(question["id"], Endpoint.url() <> "/objects/")
    assert is_binary(question["context"])
    assert String.starts_with?(question["context"], Endpoint.url() <> "/contexts/")
    assert question["content"] == "<p>hello</p>"
    assert question["source"]["content"] == "hello"
    assert question["source"]["mediaType"] == "text/plain"
    assert is_binary(question["published"])
  end
end
