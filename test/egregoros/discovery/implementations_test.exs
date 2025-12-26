defmodule Egregoros.Discovery.ImplementationsTest do
  use ExUnit.Case, async: true

  alias Egregoros.Discovery.DHT
  alias Egregoros.Discovery.DNS

  test "DNS discovery returns an empty peer list by default" do
    assert DNS.peers() == []
  end

  test "DHT discovery returns an empty peer list by default" do
    assert DHT.peers() == []
  end
end
