defmodule PleromaRedux.PipelineTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Object
  alias PleromaRedux.Pipeline

  @note %{
    "id" => "https://example.com/objects/1",
    "type" => "Note",
    "attributedTo" => "https://example.com/users/alice",
    "content" => "Hello from pipeline"
  }

  test "ingest stores a Note as an object" do
    assert {:ok, %Object{} = object} = Pipeline.ingest(@note, local: true)
    assert object.ap_id == @note["id"]
    assert object.type == "Note"
    assert object.actor == @note["attributedTo"]
    assert object.data["content"] == "Hello from pipeline"
    assert object.local == true
  end

  test "ingest rejects unknown types" do
    assert {:error, :unknown_type} =
             Pipeline.ingest(%{"type" => "Wobble", "id" => "x"}, local: true)
  end

  test "ingest rejects empty content" do
    assert {:error, :invalid} =
             Pipeline.ingest(Map.put(@note, "content", "  "), local: true)
  end
end
