ExUnit.start()
Mox.defmock(Egregoros.Auth.Mock, for: Egregoros.Auth)
Mox.defmock(Egregoros.Discovery.Mock, for: Egregoros.Discovery)
Mox.defmock(Egregoros.HTTP.Mock, for: Egregoros.HTTP)
Mox.defmock(Egregoros.DNS.Mock, for: Egregoros.DNS)
Mox.defmock(Egregoros.AuthZ.Mock, for: Egregoros.AuthZ)
Mox.defmock(Egregoros.Config.Mock, for: Egregoros.Config)
Mox.defmock(Egregoros.AvatarStorage.Mock, for: Egregoros.AvatarStorage)
Mox.defmock(Egregoros.BannerStorage.Mock, for: Egregoros.BannerStorage)
Mox.defmock(Egregoros.MediaStorage.Mock, for: Egregoros.MediaStorage)
Mox.defmock(Egregoros.HTML.Sanitizer.Mock, for: Egregoros.HTML.Sanitizer)
Mox.defmock(Egregoros.RateLimiter.Mock, for: Egregoros.RateLimiter)
Mox.defmock(Egregoros.PleromaMigration.Source.Mock, for: Egregoros.PleromaMigration.Source)

Mox.defmock(Egregoros.PleromaMigration.PostgresClient.Mock,
  for: Egregoros.PleromaMigration.PostgresClient
)

Mox.defmock(EgregorosWeb.WebSock.Mock, for: EgregorosWeb.WebSock)
Ecto.Adapters.SQL.Sandbox.mode(Egregoros.Repo, :manual)

# Ensure system actors exist outside the SQL sandbox so async tests don't fight over
# creating them inside long-running sandbox transactions.
Ecto.Adapters.SQL.Sandbox.unboxed_run(Egregoros.Repo, fn ->
  {:ok, _} = Egregoros.Users.get_or_create_local_user("internal.fetch")
  {:ok, _} = Egregoros.Federation.InstanceActor.get_actor()
end)
