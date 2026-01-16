defmodule Egregoros.ConfigTest do
  use ExUnit.Case, async: true

  import Mox

  alias Egregoros.Config

  setup :verify_on_exit!

  test "get/2 delegates to the configured impl" do
    Config.put_impl(Egregoros.Config.Mock)

    expect(Egregoros.Config.Mock, :get, fn :my_key, :default ->
      :value
    end)

    assert Config.get(:my_key, :default) == :value
  end

  test "clear_impl/0 removes per-process overrides" do
    Config.put_impl(Egregoros.Config.Mock)

    stub(Egregoros.Config.Mock, :get, fn _key, default ->
      {:from_mock, default}
    end)

    assert Config.get(:my_key, :default) == {:from_mock, :default}

    Config.clear_impl()

    assert Config.get(:__nonexistent_config_key__, :fallback) == :fallback
  end

  test "with_impl/2 temporarily overrides the impl and restores it" do
    Config.put_impl(Egregoros.Config.Mock)

    stub(Egregoros.Config.Mock, :get, fn :original_key, _default ->
      :from_original
    end)

    assert Config.with_impl(Egregoros.Config.Application, fn ->
             Config.get(:__nonexistent_config_key__, :fallback)
           end) == :fallback

    assert Config.get(:original_key, :default) == :from_original
  end

  test "with_impl/2 clears the impl when none was previously set" do
    Config.clear_impl()

    expect(Egregoros.Config.Mock, :get, fn :my_key, :default ->
      :from_mock
    end)

    assert Config.with_impl(Egregoros.Config.Mock, fn ->
             Config.get(:my_key, :default)
           end) == :from_mock

    assert Config.get(:__nonexistent_config_key__, :fallback) == :fallback
  end
end
