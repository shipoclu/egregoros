defmodule Egregoros.MiniApps.FetcherTest do
  use ExUnit.Case, async: true

  import Mox

  alias Egregoros.MiniApps.Fetcher

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "delegates to the configured fetcher" do
    expect(Egregoros.MiniApps.Fetcher.Mock, :get, fn
      "https://app.example/.well-known/fediverse-miniapp.json", :manifest ->
        {:ok, %{status: 200, body: "{}", headers: []}}
    end)

    assert {:ok, %{body: "{}"}} =
             Fetcher.get("https://app.example/.well-known/fediverse-miniapp.json", :manifest)
  end
end
