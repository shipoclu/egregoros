defmodule Egregoros.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Egregoros.RuntimeConfig

  test "get/2 reads from Application env by default" do
    assert RuntimeConfig.get(:uploads_dir) == Application.fetch_env!(:egregoros, :uploads_dir)
    assert RuntimeConfig.get(:this_key_does_not_exist, :fallback) == :fallback
  end

  test "with/2 overrides config for the current process only" do
    original = RuntimeConfig.get(:uploads_dir)

    RuntimeConfig.with(%{uploads_dir: "override"}, fn ->
      assert RuntimeConfig.get(:uploads_dir) == "override"

      parent = self()

      spawn(fn ->
        send(parent, {:uploads_dir, RuntimeConfig.get(:uploads_dir)})
      end)

      assert_receive {:uploads_dir, ^original}
    end)

    assert RuntimeConfig.get(:uploads_dir) == original
  end
end
