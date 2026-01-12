defmodule Egregoros.Workers.RefreshRemoteUserCountsTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Workers.RefreshRemoteUserCounts

  test "rejects invalid args" do
    assert {:discard, :invalid_args} = RefreshRemoteUserCounts.perform(%Oban.Job{args: %{}})

    assert {:discard, :invalid_args} =
             RefreshRemoteUserCounts.perform(%Oban.Job{args: %{"ap_id" => 123}})
  end

  test "returns an error when the actor url is unsafe" do
    assert {:error, :unsafe_url} =
             RefreshRemoteUserCounts.perform(%Oban.Job{args: %{"ap_id" => "not-a-url"}})
  end
end
