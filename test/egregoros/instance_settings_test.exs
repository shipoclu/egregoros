defmodule Egregoros.InstanceSettingsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.InstanceSettings

  test "registrations are open by default" do
    assert InstanceSettings.registrations_open?()
  end

  test "registrations can be closed" do
    assert {:ok, _settings} = InstanceSettings.set_registrations_open(false)
    refute InstanceSettings.registrations_open?()
  end
end

