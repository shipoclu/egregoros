ExUnit.start()
Mox.defmock(PleromaRedux.Auth.Mock, for: PleromaRedux.Auth)
Mox.defmock(PleromaRedux.Discovery.Mock, for: PleromaRedux.Discovery)
Ecto.Adapters.SQL.Sandbox.mode(PleromaRedux.Repo, :manual)
