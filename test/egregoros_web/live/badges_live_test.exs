defmodule EgregorosWeb.BadgesLiveTest do
  use EgregorosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Egregoros.Activities.Accept
  alias Egregoros.Pipeline
  alias Egregoros.TestSupport.Fixtures
  alias Egregoros.Users

  setup do
    {:ok, recipient} = Users.create_local_user("badge_recipient")

    %{recipient: recipient}
  end

  test "badges list renders accepted badges with validity", %{conn: conn, recipient: recipient} do
    {_offer, accept} = accept_badge_offer(recipient)

    {:ok, view, _html} = live(conn, "/@#{recipient.nickname}/badges")

    assert has_element?(view, "#badge-#{accept.id}")

    assert has_element?(
             view,
             "#badge-#{accept.id} [data-role='badge-title']",
             "Donator"
           )

    assert has_element?(
             view,
             "#badge-#{accept.id} [data-role='badge-validity']",
             "Valid"
           )
  end

  test "badge detail renders the badge card and image", %{conn: conn, recipient: recipient} do
    {_offer, accept} = accept_badge_offer(recipient)

    {:ok, view, _html} = live(conn, "/@#{recipient.nickname}/badges/#{accept.id}")

    assert has_element?(view, "[data-role='badge-detail']")
    assert has_element?(view, "[data-role='badge-detail'] [data-role='badge-title']", "Donator")
    assert has_element?(view, "[data-role='badge-detail'] img[data-role='badge-image']")
  end

  test "badges list shows a share button for signed-in users", %{
    conn: conn,
    recipient: recipient
  } do
    {_offer, accept} = accept_badge_offer(recipient)

    conn = Plug.Test.init_test_session(conn, %{user_id: recipient.id})

    {:ok, view, _html} = live(conn, "/@#{recipient.nickname}/badges")

    assert has_element?(view, "#badge-#{accept.id} [data-role='badge-share']")
  end

  test "badges list shows a copy url button", %{conn: conn, recipient: recipient} do
    {_offer, accept} = accept_badge_offer(recipient)

    {:ok, view, _html} = live(conn, "/@#{recipient.nickname}/badges")

    assert has_element?(view, "#badge-#{accept.id} [data-role='badge-copy-url']")
  end

  test "sharing a badge shows a toast message", %{conn: conn, recipient: recipient} do
    {_offer, accept} = accept_badge_offer(recipient)

    conn = Plug.Test.init_test_session(conn, %{user_id: recipient.id})

    {:ok, view, _html} = live(conn, "/@#{recipient.nickname}/badges")

    view
    |> element("#badge-#{accept.id} [data-role='badge-share']")
    |> render_click()

    assert has_element?(view, "[data-role='toast']", "Badge shared.")
  end

  test "badge detail shows a copy url button", %{conn: conn, recipient: recipient} do
    {_offer, accept} = accept_badge_offer(recipient)

    {:ok, view, _html} = live(conn, "/@#{recipient.nickname}/badges/#{accept.id}")

    assert has_element?(view, "[data-role='badge-detail'] [data-role='badge-copy-url']")
  end

  defp accept_badge_offer(recipient) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    credential =
      Fixtures.json!("openbadge_vc.json")
      |> Map.put("issuer", "https://example.com/users/issuer")
      |> Map.put("to", [recipient.ap_id])
      |> put_in(["credentialSubject", "id"], recipient.ap_id)
      |> Map.put("validFrom", DateTime.add(now, -3600, :second) |> DateTime.to_iso8601())
      |> Map.put("validUntil", DateTime.add(now, 86_400, :second) |> DateTime.to_iso8601())

    offer = %{
      "id" => "https://example.com/activities/offer/#{Ecto.UUID.generate()}",
      "type" => "Offer",
      "actor" => "https://example.com/users/issuer",
      "to" => [recipient.ap_id],
      "object" => credential,
      "published" => DateTime.to_iso8601(now)
    }

    {:ok, offer_object} =
      Pipeline.ingest(offer, local: false, inbox_user_ap_id: recipient.ap_id)

    {:ok, accept_object} = Pipeline.ingest(Accept.build(recipient, offer_object), local: true)

    {offer_object, accept_object}
  end
end
