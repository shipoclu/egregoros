defmodule PleromaRedux.ObjectsTest do
  use PleromaRedux.DataCase, async: true

  alias PleromaRedux.Object
  alias PleromaRedux.Objects

  @attrs %{
    ap_id: "https://example.com/objects/1",
    type: "Note",
    actor: "https://example.com/users/alice",
    object: nil,
    data: %{"type" => "Note", "content" => "Hello from Redux"},
    published: ~U[2025-01-01 00:00:00Z],
    local: true
  }

  test "create_object stores jsonb data" do
    assert {:ok, %Object{} = object} = Objects.create_object(@attrs)
    assert object.ap_id == @attrs.ap_id
    assert object.data["content"] == "Hello from Redux"
  end

  test "get_by_ap_id returns stored object" do
    assert {:ok, %Object{} = object} = Objects.create_object(@attrs)
    assert %Object{id: id} = Objects.get_by_ap_id(@attrs.ap_id)
    assert id == object.id
  end

  test "ap_id is unique" do
    assert {:ok, %Object{}} = Objects.create_object(@attrs)
    assert {:error, changeset} = Objects.create_object(@attrs)
    assert "has already been taken" in errors_on(changeset).ap_id
  end
end
