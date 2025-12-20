defmodule PleromaRedux.HTML do
  @moduledoc false

  @default_scrubber PleromaRedux.HTML.Scrubber.Default

  def sanitize(nil), do: ""

  def sanitize(html) when is_binary(html) do
    {:ok, content} = FastSanitize.Sanitizer.scrub(html, @default_scrubber)
    content
  end

  def sanitize(_), do: ""

  def to_safe_html(content, opts \\ [])

  def to_safe_html(nil, _opts), do: ""

  def to_safe_html(content, opts) when is_binary(content) do
    format = Keyword.get(opts, :format, :html)
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        ""

      format == :text ->
        trimmed
        |> text_to_html()
        |> sanitize()

      format == :html and looks_like_html?(trimmed) ->
        sanitize(trimmed)

      true ->
        trimmed
        |> text_to_html()
        |> sanitize()
    end
  end

  def to_safe_html(_content, _opts), do: ""

  defp looks_like_html?(content) when is_binary(content) do
    String.contains?(content, "<") and String.contains?(content, ">")
  end

  defp text_to_html(text) when is_binary(text) do
    text =
      text
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    escaped =
      text
      |> Plug.HTML.html_escape_to_iodata()
      |> IO.iodata_to_binary()

    escaped = String.replace(escaped, "\n", "<br>")

    "<p>" <> escaped <> "</p>"
  end
end
