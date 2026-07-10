defmodule Egregoros.MiniApps.ComposeDraft do
  @moduledoc false

  alias Egregoros.MiniApps.Card
  alias Egregoros.MiniApps.LaunchContext

  @draft_fields ~w(text spoilerText language visibility inReplyTo links)
  @visibilities ~w(public unlisted followers direct)
  @language ~r/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/
  @max_text_chars 5_000
  @max_spoiler_chars 500
  @max_links 8
  @max_url_bytes 2_048

  def prepare(%Card{} = card, draft) when is_map(draft) do
    with :ok <- only_fields(draft),
         {:ok, text} <- bounded_string(Map.get(draft, "text", ""), @max_text_chars, :too_long),
         {:ok, spoiler_text} <-
           bounded_string(Map.get(draft, "spoilerText", ""), @max_spoiler_chars, :too_long),
         {:ok, language} <- language(Map.get(draft, "language", "")),
         {:ok, visibility} <- visibility(Map.get(draft, "visibility", "public")),
         {:ok, links} <- links(Map.get(draft, "links", [])),
         {:ok, content} <- append_links(text, links),
         {:ok, in_reply_to} <- reply_target(card, Map.get(draft, "inReplyTo")) do
      {:ok,
       %{
         "content" => content,
         "spoiler_text" => spoiler_text,
         "language" => language,
         "visibility" => visibility,
         "in_reply_to" => in_reply_to
       }}
    end
  end

  def prepare(_card, _draft), do: {:error, :invalid_draft}

  def validate_form(params) when is_map(params) do
    with {:ok, content} <-
           bounded_string(Map.get(params, "content", ""), @max_text_chars, :too_long),
         {:ok, spoiler_text} <-
           bounded_string(
             Map.get(params, "spoiler_text", ""),
             @max_spoiler_chars,
             :too_long
           ),
         {:ok, language} <- language(Map.get(params, "language", "")),
         {:ok, scope} <- visibility(Map.get(params, "visibility", "public")) do
      {:ok,
       %{
         content: content,
         spoiler_text: spoiler_text,
         language: language,
         visibility: publish_visibility(scope),
         scope: scope
       }}
    end
  end

  def validate_form(_params), do: {:error, :invalid_draft}

  defp only_fields(draft) do
    if Enum.all?(Map.keys(draft), &(&1 in @draft_fields)),
      do: :ok,
      else: {:error, :invalid_draft}
  end

  defp bounded_string(value, max, error) when is_binary(value) do
    if String.length(value) <= max, do: {:ok, value}, else: {:error, error}
  end

  defp bounded_string(_value, _max, _error), do: {:error, :invalid_draft}

  defp language(""), do: {:ok, ""}

  defp language(value) when is_binary(value) do
    if String.length(value) <= 35 and String.match?(value, @language),
      do: {:ok, value},
      else: {:error, :invalid_language}
  end

  defp language(_value), do: {:error, :invalid_language}

  defp visibility(value) when value in @visibilities, do: {:ok, value}
  defp visibility(_value), do: {:error, :invalid_visibility}

  defp links(values) when is_list(values) and length(values) <= @max_links do
    if Enum.all?(values, &valid_link?/1),
      do: {:ok, Enum.uniq(values)},
      else: {:error, :invalid_link}
  end

  defp links(_values), do: {:error, :invalid_link}

  defp valid_link?(value) when is_binary(value) and byte_size(value) <= @max_url_bytes do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp valid_link?(_value), do: false

  defp append_links(text, []), do: {:ok, text}

  defp append_links(text, links) do
    content = String.trim_trailing(text) <> "\n\n" <> Enum.join(links, "\n")

    if String.length(content) <= @max_text_chars,
      do: {:ok, content},
      else: {:error, :too_long}
  end

  defp reply_target(_card, value) when value in [nil, ""], do: {:ok, nil}

  defp reply_target(card, value) when is_binary(value) do
    case LaunchContext.for_card(card) do
      {:ok, %{"note" => %{"id" => ^value}}} -> {:ok, value}
      _ -> {:error, :invalid_reply_target}
    end
  end

  defp reply_target(_card, _value), do: {:error, :invalid_reply_target}

  defp publish_visibility("followers"), do: "private"
  defp publish_visibility(scope), do: scope
end
