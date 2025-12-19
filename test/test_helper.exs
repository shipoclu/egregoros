ExUnit.start()
Mox.defmock(PleromaRedux.Auth.Mock, for: PleromaRedux.Auth)
Ecto.Adapters.SQL.Sandbox.mode(PleromaRedux.Repo, :manual)
