defmodule Egregoros.ObanCronConfigTest do
  use ExUnit.Case, async: true

  test "Oban cron schedules a daily remote-following graph refresh" do
    oban_config = Application.get_env(:egregoros, Oban, [])
    plugins = Keyword.get(oban_config, :plugins, [])

    cron =
      Enum.find(plugins, fn
        {Oban.Plugins.Cron, _opts} -> true
        _ -> false
      end)

    assert {Oban.Plugins.Cron, cron_opts} = cron

    crontab = Keyword.fetch!(cron_opts, :crontab)

    assert Enum.any?(crontab, fn
             {"@daily", Egregoros.Workers.RefreshRemoteFollowingGraphsDaily} ->
               true

             {"@daily", Egregoros.Workers.RefreshRemoteFollowingGraphsDaily, _job_opts} ->
               true

             _ ->
               false
           end)
  end
end
