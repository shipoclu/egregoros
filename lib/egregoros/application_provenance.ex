defmodule Egregoros.ApplicationProvenance do
  @moduledoc false

  alias Egregoros.OAuth.Application, as: OAuthApplication

  @activitystreams_context "https://www.w3.org/ns/activitystreams"
  @context "https://ns.fediverse.org/context/application-provenance/v1.jsonld"
  @vocabulary "https://ns.fediverse.org/vocab/application-provenance#"

  def generator(%OAuthApplication{kind: "miniapp", website: website} = application)
      when is_binary(website) and website != "" do
    %{
      "id" => website,
      "type" => "Application",
      "name" => application.name,
      "url" => website,
      "fap:kind" => "miniapp"
    }
  end

  def generator(_application), do: nil

  def put_metadata(object, opts) when is_map(object) and is_list(opts) do
    generator = Keyword.get(opts, :generator)
    promotional = Keyword.get(opts, :promotional, false)

    object
    |> maybe_put_generator(generator)
    |> maybe_put_promotional(promotional)
    |> maybe_put_context(is_map(generator) or promotional == true)
  end

  def copy_to_activity(activity, object) when is_map(activity) and is_map(object) do
    Enum.reduce(["@context", "generator", "fap:promotional"], activity, fn key, acc ->
      case Map.fetch(object, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  def render_application(%{"generator" => %{} = generator}) do
    kind = Map.get(generator, "fap:kind")
    types = generator |> Map.get("type") |> List.wrap()

    if kind == "miniapp" and "Application" in types do
      %{
        "name" => string_or_nil(Map.get(generator, "name")),
        "website" =>
          string_or_nil(Map.get(generator, "url")) || string_or_nil(Map.get(generator, "id")),
        "kind" => kind
      }
    end
  end

  def render_application(_data), do: nil

  def promotional?(%{"fap:promotional" => true}), do: true
  def promotional?(_data), do: false

  def context do
    [
      @activitystreams_context,
      @context,
      %{"fap" => @vocabulary}
    ]
  end

  defp maybe_put_generator(object, %{} = generator), do: Map.put(object, "generator", generator)
  defp maybe_put_generator(object, _generator), do: object

  defp maybe_put_promotional(object, true), do: Map.put(object, "fap:promotional", true)
  defp maybe_put_promotional(object, _promotional), do: object

  defp maybe_put_context(object, true), do: Map.put(object, "@context", context())
  defp maybe_put_context(object, false), do: object

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil
end
