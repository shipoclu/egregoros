defmodule Egregoros.MiniApps.Discovery do
  @moduledoc """
  Pure, bounded extraction of mini-app candidate URLs from public notes.

  This module deliberately performs no network or persistence work. A later
  discovery worker may try candidates in order and stop at the first URL whose
  origin publishes a valid mini-app manifest.
  """

  alias Egregoros.MiniApps.Origin
  alias Egregoros.Object

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @max_content_bytes 100_000
  @max_candidates 10
  @ignored_tags ~w(script style template noscript iframe object embed)a
  @non_content_anchor_classes ~w(mention mention-link hashtag)
  @plain_https_url ~r/https:\/\/[^\s<>"']+/u
  @trailing_punctuation ".,!?;:)]}"

  def candidate_urls(%Object{type: "Note", data: %{} = data}) do
    with true <- listed_public?(data),
         content when is_binary(content) <- Map.get(data, "content"),
         true <- byte_size(content) <= @max_content_bytes,
         true <- String.valid?(content),
         {:ok, tree} <- FastSanitize.Fragment.to_tree(content) do
      tree
      |> extract_nodes(false)
      |> Enum.filter(&eligible_url?/1)
      |> Enum.uniq()
      |> Enum.take(@max_candidates)
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  def candidate_urls(_object), do: []

  defp listed_public?(data) do
    data
    |> Map.get("to", [])
    |> List.wrap()
    |> Enum.member?(@as_public)
  end

  defp extract_nodes(nodes, inside_anchor?) when is_list(nodes) do
    Enum.flat_map(nodes, &extract_node(&1, inside_anchor?))
  end

  defp extract_nodes(_nodes, _inside_anchor?), do: []

  defp extract_node(text, false) when is_binary(text), do: plain_urls(text)
  defp extract_node(text, true) when is_binary(text), do: []
  defp extract_node({:comment, _, _}, _inside_anchor?), do: []

  defp extract_node({tag, _attributes, _children}, _inside_anchor?)
       when tag in @ignored_tags,
       do: []

  defp extract_node({:a, attributes, children}, _inside_anchor?) do
    urls =
      if content_anchor?(attributes) do
        case attribute(attributes, "href") do
          href when is_binary(href) -> [String.trim(href)]
          _ -> []
        end
      else
        []
      end

    urls ++ extract_nodes(children, true)
  end

  defp extract_node({_tag, _attributes, children}, inside_anchor?) do
    extract_nodes(children, inside_anchor?)
  end

  defp extract_node(_node, _inside_anchor?), do: []

  defp content_anchor?(attributes) when is_list(attributes) do
    classes =
      attributes
      |> attribute("class")
      |> case do
        value when is_binary(value) -> String.split(value, ~r/\s+/, trim: true)
        _ -> []
      end

    not Enum.any?(classes, &(&1 in @non_content_anchor_classes))
  end

  defp content_anchor?(_attributes), do: false

  defp attribute(attributes, name) do
    case Enum.find(attributes, fn
           {key, _value} -> to_string(key) == name
           _ -> false
         end) do
      {_key, value} -> value
      _ -> nil
    end
  end

  defp plain_urls(text) do
    @plain_https_url
    |> Regex.scan(text)
    |> Enum.map(fn [url] -> trim_plain_url(url) end)
  end

  defp trim_plain_url(url) do
    if String.contains?(@trailing_punctuation, String.last(url)) do
      url
      |> binary_part(0, byte_size(url) - 1)
      |> trim_plain_url()
    else
      url
    end
  end

  defp eligible_url?(url) when is_binary(url) and url != "" do
    match?({:ok, _origin}, Origin.from_url(url))
  end

  defp eligible_url?(_url), do: false
end
