defmodule Egregoros.DiscoveryTest do
  use ExUnit.Case, async: true

  import Mox

  test "delegates to the configured discovery module" do
    Egregoros.Discovery.Mock
    |> expect(:peers, fn -> ["https://peer.example"] end)

    assert ["https://peer.example"] == Egregoros.Discovery.peers()
  end
end
