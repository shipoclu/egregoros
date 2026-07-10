defmodule Egregoros.Federation.ResponseValidatorTest do
  use ExUnit.Case, async: true

  alias Egregoros.Federation.ResponseValidator

  test "accepts ActivityStreams response media types" do
    assert :ok =
             ResponseValidator.validate_activitystreams(%{
               status: 200,
               headers: [{"content-type", "application/activity+json; charset=utf-8"}]
             })

    assert :ok =
             ResponseValidator.validate_activitystreams(%{
               status: 200,
               headers: %{
                 "content-type" => [
                   "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
                 ]
               }
             })
  end

  test "rejects generic JSON, HTML, missing content type, and unprofiled JSON-LD" do
    for headers <- [
          [{"content-type", "application/json"}],
          [{"content-type", "text/html"}],
          [],
          [{"content-type", "application/ld+json"}]
        ] do
      assert {:error, :invalid_activitystreams_content_type} =
               ResponseValidator.validate_activitystreams(%{status: 200, headers: headers})
    end
  end

  test "does not reinterpret non-success responses" do
    assert :ok = ResponseValidator.validate_activitystreams(%{status: 404, headers: []})
  end

  test "validates WebFinger responses and fails closed on malformed response shapes" do
    assert :ok =
             ResponseValidator.validate_webfinger(%{
               status: 200,
               headers: [{"Content-Type", "application/jrd+json; charset=utf-8"}]
             })

    assert :ok = ResponseValidator.validate_webfinger(%{status: 404})

    for response <- [
          :invalid,
          %{status: 200, headers: "not-headers"},
          %{status: 200, headers: [:invalid_header]},
          %{status: 200, headers: [{"content-type", nil}]},
          %{status: 200, headers: [{"content-type", 123}]}
        ] do
      assert {:error, :invalid_webfinger_content_type} =
               ResponseValidator.validate_webfinger(response)
    end

    assert {:error, :invalid_activitystreams_content_type} =
             ResponseValidator.validate_activitystreams(:invalid)

    refute ResponseValidator.activitystreams_media_type?(nil)
  end
end
