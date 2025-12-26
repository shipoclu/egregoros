defmodule Egregoros.DNS.InetTest do
  use ExUnit.Case, async: true

  alias Egregoros.DNS.Inet

  test "returns local addresses for localhost" do
    assert {:ok, ips} = Inet.lookup_ips("localhost")
    assert is_list(ips)
    assert ips != []
  end

  test "returns :nxdomain for empty hosts" do
    assert {:error, :nxdomain} = Inet.lookup_ips("")
  end
end
