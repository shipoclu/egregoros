defmodule Egregoros.Activities.NoteMiniAppDiscoveryTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Note
  alias Egregoros.Activities.Update
  alias Egregoros.Pipeline
  alias Egregoros.Users
  alias Egregoros.Workers.ResolveMiniAppCard

  test "successful note side effects enqueue mini-app discovery without resolving inline" do
    enable_mini_apps()
    {:ok, author} = Users.create_local_user("mini-app-note-author")

    note = Note.build(author, ~s(<a href="https://app.example/read">reader</a>))
    assert {:ok, object} = Pipeline.ingest(note, local: true, deliver: false)

    assert_enqueued(
      worker: ResolveMiniAppCard,
      args: %{"object_id" => object.id}
    )
  end

  test "an edited note is scheduled for fresh discovery" do
    {:ok, author} = Users.create_local_user("mini-app-edited-note-author")
    note = Note.build(author, "before")
    assert {:ok, object} = Pipeline.ingest(note, local: true, deliver: false)
    refute_enqueued(worker: ResolveMiniAppCard)

    enable_mini_apps()

    edited = Map.put(note, "content", ~s(<a href="https://app.example/after">reader</a>))
    update = Update.build(author, edited)
    assert {:ok, _update_object} = Pipeline.ingest(update, local: true, deliver: false)

    assert_enqueued(
      worker: ResolveMiniAppCard,
      args: %{"object_id" => object.id}
    )
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
