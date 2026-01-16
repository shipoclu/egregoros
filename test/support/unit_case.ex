defmodule Egregoros.UnitCase do
  use ExUnit.CaseTemplate

  setup tags do
    Mox.set_mox_from_context(tags)
    Mox.stub_with(Egregoros.Config.Mock, Egregoros.Config.Stub)
    Mox.verify_on_exit!(tags)
    :ok
  end
end
