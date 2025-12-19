defmodule PleromaRedux.DiscoveryTest do
  use ExUnit.Case, async: true

  import Mox

  test "delegates to the configured discovery module" do
    PleromaRedux.Discovery.Mock
    |> expect(:peers, fn -> ["https://peer.example"] end)

    assert ["https://peer.example"] == PleromaRedux.Discovery.peers()
  end
end
