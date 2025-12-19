defmodule PleromaRedux.HTTPTest do
  use ExUnit.Case, async: true

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "delegates to configured module" do
    PleromaRedux.HTTP.Mock
    |> expect(:get, fn "https://example.com", [] ->
      {:ok, %{status: 200, body: "", headers: []}}
    end)

    assert {:ok, %{status: 200}} = PleromaRedux.HTTP.get("https://example.com")
  end
end
