defmodule PleromaRedux.Discovery.ImplementationsTest do
  use ExUnit.Case, async: true

  alias PleromaRedux.Discovery.DHT
  alias PleromaRedux.Discovery.DNS

  test "DNS discovery returns an empty peer list by default" do
    assert DNS.peers() == []
  end

  test "DHT discovery returns an empty peer list by default" do
    assert DHT.peers() == []
  end
end

