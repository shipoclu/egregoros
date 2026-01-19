defmodule Egregoros.Activities.NoteCastAndValidateTest do
  use ExUnit.Case, async: true

  alias Egregoros.Activities.Note

  test "copies attributedTo into actor and trims content" do
    note = %{
      "id" => "https://example.com/objects/1",
      "type" => "Note",
      "attributedTo" => "https://example.com/users/alice",
      "content" => "  hello  "
    }

    assert {:ok, validated} = Note.cast_and_validate(note)
    assert validated["actor"] == "https://example.com/users/alice"
    assert validated["content"] == "hello"
  end

  test "rejects blank content" do
    note = %{
      "id" => "https://example.com/objects/1",
      "type" => "Note",
      "attributedTo" => "https://example.com/users/alice",
      "content" => "   "
    }

    assert {:error, %Ecto.Changeset{}} = Note.cast_and_validate(note)
  end

  test "allows blank content when attachments are present" do
    note = %{
      "id" => "https://example.com/objects/1",
      "type" => "Note",
      "attributedTo" => "https://example.com/users/alice",
      "content" => "",
      "attachment" => [
        %{
          "type" => "Document",
          "mediaType" => "image/webp",
          "url" => "https://cdn.example/media/1.webp",
          "name" => ""
        }
      ]
    }

    assert {:ok, validated} = Note.cast_and_validate(note)
    assert validated["content"] == ""
  end

  test "rejects remote notes over 20_000 characters" do
    note = %{
      "id" => "https://example.com/objects/1",
      "type" => "Note",
      "attributedTo" => "https://example.com/users/alice",
      "content" => String.duplicate("a", 20_001)
    }

    assert {:error, :too_long} = Note.cast_and_validate(note, local: false)
  end

  test "accepts remote notes at 20_000 characters" do
    note = %{
      "id" => "https://example.com/objects/1",
      "type" => "Note",
      "attributedTo" => "https://example.com/users/alice",
      "content" => String.duplicate("a", 20_000)
    }

    assert {:ok, validated} = Note.cast_and_validate(note, local: false)
    assert String.length(validated["content"]) == 20_000
  end
end
