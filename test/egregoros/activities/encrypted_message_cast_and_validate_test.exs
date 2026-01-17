defmodule Egregoros.Activities.EncryptedMessageCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.EncryptedMessage

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  test "accepts EncryptedMessage objects with an e2ee payload" do
    msg = %{
      "id" => "https://example.com/objects/1",
      "type" => "EncryptedMessage",
      "attributedTo" => "https://example.com/users/alice",
      "to" => ["https://example.com/users/bob"],
      "content" => "  Encrypted message  ",
      "egregoros:e2ee_dm" => %{"version" => 1, "ciphertext" => "abc"}
    }

    assert {:ok, validated} = EncryptedMessage.cast_and_validate(msg)
    assert validated["type"] == "EncryptedMessage"
    assert validated["actor"] == "https://example.com/users/alice"
    assert validated["content"] == "Encrypted message"
  end

  test "build/2 emits an EncryptedMessage object" do
    msg = EncryptedMessage.build("https://example.com/users/alice", "Encrypted message")

    assert msg["type"] == "EncryptedMessage"
    assert msg["attributedTo"] == "https://example.com/users/alice"
    assert is_binary(msg["id"])
  end

  test "rejects EncryptedMessage objects without an e2ee payload" do
    msg = %{
      "id" => "https://example.com/objects/1",
      "type" => "EncryptedMessage",
      "attributedTo" => "https://example.com/users/alice",
      "to" => ["https://example.com/users/bob"],
      "content" => "Encrypted message"
    }

    assert {:error, %Ecto.Changeset{}} = EncryptedMessage.cast_and_validate(msg)
  end

  test "rejects EncryptedMessage objects addressed to Public" do
    msg = %{
      "id" => "https://example.com/objects/1",
      "type" => "EncryptedMessage",
      "attributedTo" => "https://example.com/users/alice",
      "to" => [@as_public],
      "content" => "Encrypted message",
      "egregoros:e2ee_dm" => %{"version" => 1, "ciphertext" => "abc"}
    }

    assert {:error, %Ecto.Changeset{}} = EncryptedMessage.cast_and_validate(msg)
  end

  test "rejects non-map inputs" do
    assert {:error, %Ecto.Changeset{}} = EncryptedMessage.cast_and_validate("nope")
  end
end
