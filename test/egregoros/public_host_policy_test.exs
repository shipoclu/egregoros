defmodule Egregoros.PublicHostPolicyTest do
  use ExUnit.Case, async: true

  import Mox

  alias Egregoros.PublicHostPolicy

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "normalizes configured public aliases and compares hostnames without ports" do
    stub(Egregoros.Config.Mock, :get, fn
      :public_host_aliases, [] -> ["Social.Example.", "alt.example:8443", "bad alias"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert PublicHostPolicy.cookie_host?("social.example")
      assert PublicHostPolicy.cookie_host?("ALT.EXAMPLE")
      refute PublicHostPolicy.cookie_host?("app.example")
    end)
  end

  test "also treats the browser-visible request host as a cookie host" do
    stub(Egregoros.Config.Mock, :get, fn
      :public_host_aliases, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    Egregoros.Config.with_impl(Egregoros.Config.Mock, fn ->
      assert PublicHostPolicy.cookie_host?("app.example", "App.Example.")
      refute PublicHostPolicy.cookie_host?("other.example", "app.example")
    end)
  end
end
