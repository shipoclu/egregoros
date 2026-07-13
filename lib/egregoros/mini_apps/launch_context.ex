defmodule Egregoros.MiniApps.LaunchContext do
  @moduledoc false

  alias Egregoros.MiniApps.Card
  alias Egregoros.Object
  alias Egregoros.Objects
  alias Egregoros.Repo

  @max_content_chars 5_000
  @max_mentions 32

  def public_for_card(%Card{} = card) do
    with %Object{type: "Note"} = object <- Repo.get(Object, card.object_id),
         true <- Objects.publicly_listed?(object),
         true <- public_source_id?(object.ap_id),
         true <- public_https_url?(card.launch_url, allow_fragment: true),
         true <- public_https_url?(card.source_url, allow_fragment: true) do
      {:ok,
       %{
         "version" => "1",
         "launchUrl" => card.launch_url,
         "linkedUrl" => card.source_url,
         "sourceNoteId" => object.ap_id
       }}
    else
      _ -> {:error, :ineligible_note}
    end
  end

  def public_for_card(_card), do: {:error, :ineligible_note}

  def for_card(%Card{} = card) do
    with %Object{type: "Note"} = object <- Repo.get(Object, card.object_id),
         true <- Objects.publicly_listed?(object) do
      {:ok,
       %{
         "version" => "1",
         "launchUrl" => card.launch_url,
         "sourceUrl" => card.source_url,
         "note" => %{
           "id" => object.ap_id,
           "url" => object.ap_id,
           "content" => public_text(object),
           "author" => object.actor,
           "mentions" => public_mentions(object)
         }
       }}
    else
      _ -> {:error, :ineligible_note}
    end
  end

  def for_card(_card), do: {:error, :ineligible_note}

  defp public_text(%Object{data: %{"content" => content}}) when is_binary(content) do
    content
    |> FastSanitize.strip_tags()
    |> case do
      {:ok, text} -> IO.iodata_to_binary(text)
      _ -> ""
    end
    |> String.trim()
    |> String.slice(0, @max_content_chars)
  end

  defp public_text(_object), do: ""

  defp public_mentions(%Object{data: %{} = data}) do
    data
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "Mention"))
    |> Enum.map(&(Map.get(&1, "href") || Map.get(&1, "id")))
    |> Enum.filter(&(is_binary(&1) and &1 != "" and byte_size(&1) <= 2_048))
    |> Enum.uniq()
    |> Enum.take(@max_mentions)
  end

  defp public_mentions(_object), do: []

  defp public_https_url?(value, opts) when is_binary(value) and byte_size(value) <= 2_048 do
    allow_fragment? = Keyword.get(opts, :allow_fragment, false)

    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: fragment}
      when is_binary(host) and host != "" ->
        allow_fragment? or is_nil(fragment)

      _ ->
        false
    end
  end

  defp public_https_url?(_value, _opts), do: false

  defp public_source_id?(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp public_source_id?(_value), do: false
end
