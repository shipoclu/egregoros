defmodule Egregoros.HTML.Scrubber.Default do
  @moduledoc false

  require FastSanitize.Sanitizer.Meta

  alias FastSanitize.Sanitizer.Meta

  @valid_schemes ["http", "https", "mailto"]

  @allowed_a_classes ~w(mention-link mention u-url hashtag)
  @allowed_img_classes ~w(emoji)
  @emoji_alt_regex ~r/^:[A-Za-z0-9_+-]{1,64}:$/

  Meta.allow_tag_with_uri_attributes(:a, ["href"], @valid_schemes)
  Meta.allow_tag_with_this_attribute_values(:a, "target", ["_blank", "_self", "_top", "_parent"])

  # -------------------------------------------------------------------------
  # Attribute rules (group scrub_attribute/2 clauses together)
  # -------------------------------------------------------------------------
  def scrub_attribute(:a, {"class", value}), do: scrub_class(value, @allowed_a_classes)
  def scrub_attribute(:a, {"rel", value}), do: {"rel", value}
  def scrub_attribute(:a, {"title", value}), do: {"title", value}

  def scrub_attribute(:img, {"src", "&" <> _value}), do: nil

  def scrub_attribute(:img, {"src", value}) when is_binary(value) do
    value = String.trim(value)

    case Egregoros.SafeURL.validate_http_url_no_dns(value) do
      :ok -> {"src", value}
      _ -> nil
    end
  end

  def scrub_attribute(:img, {"src", _value}), do: nil
  def scrub_attribute(:img, {"class", value}), do: scrub_class(value, @allowed_img_classes)
  def scrub_attribute(:img, {"alt", value}) when is_binary(value), do: {"alt", value}
  def scrub_attribute(:img, {"title", value}) when is_binary(value), do: {"title", value}

  def scrub_attribute(:img, {attr, value})
      when attr in ["width", "height"] and is_binary(value) do
    if String.match?(value, ~r/^\d+$/) do
      {attr, value}
    else
      nil
    end
  end

  def scrub_attribute(_tag, _attribute), do: nil

  # -------------------------------------------------------------------------
  # Node rules (group scrub/1 clauses together)
  # -------------------------------------------------------------------------
  def scrub({:comment, _, _}), do: nil

  def scrub({:a, attributes, children}) do
    attributes =
      attributes
      |> Enum.map(&scrub_attribute(:a, &1))
      |> Enum.reject(&is_nil/1)
      |> ensure_safe_rel()

    {:a, attributes, children}
  end

  def scrub({:img, attributes, children}) do
    attributes =
      attributes
      |> Enum.map(&scrub_attribute(:img, &1))
      |> Enum.reject(&is_nil/1)

    if emoji_img?(attributes) do
      {:img, ensure_img_class(attributes, "emoji"), children}
    else
      nil
    end
  end

  Meta.allow_tag_with_these_attributes(:p, [])
  Meta.allow_tag_with_these_attributes(:br, [])
  Meta.allow_tag_with_these_attributes(:span, [])
  Meta.allow_tag_with_these_attributes(:blockquote, [])
  Meta.allow_tag_with_these_attributes(:pre, [])
  Meta.allow_tag_with_these_attributes(:code, [])

  Meta.allow_tag_with_these_attributes(:strong, [])
  Meta.allow_tag_with_these_attributes(:em, [])
  Meta.allow_tag_with_these_attributes(:b, [])
  Meta.allow_tag_with_these_attributes(:i, [])
  Meta.allow_tag_with_these_attributes(:u, [])
  Meta.allow_tag_with_these_attributes(:s, [])
  Meta.allow_tag_with_these_attributes(:small, [])
  Meta.allow_tag_with_these_attributes(:sub, [])
  Meta.allow_tag_with_these_attributes(:sup, [])
  Meta.allow_tag_with_these_attributes(:del, [])

  Meta.allow_tag_with_these_attributes(:ul, [])
  Meta.allow_tag_with_these_attributes(:ol, [])
  Meta.allow_tag_with_these_attributes(:li, [])

  def scrub({_tag, _attributes, children}), do: children
  def scrub("" <> _ = text), do: text

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------
  defp ensure_safe_rel(attributes) when is_list(attributes) do
    required = ["nofollow", "noopener", "noreferrer"]

    {rel, attributes} = pop_attribute(attributes, "rel")

    tokens =
      rel
      |> List.wrap()
      |> Enum.join(" ")
      |> String.split(~r/\s+/, trim: true)

    tokens =
      Enum.reduce(required, tokens, fn token, acc ->
        if Enum.any?(acc, &(String.downcase(&1) == token)) do
          acc
        else
          acc ++ [token]
        end
      end)

    attributes ++ [{"rel", Enum.join(tokens, " ")}]
  end

  defp pop_attribute(attributes, key) when is_list(attributes) and is_binary(key) do
    {matches, rest} = Enum.split_with(attributes, fn {attr, _value} -> attr == key end)

    value =
      case matches do
        [{^key, value} | _] -> value
        _ -> nil
      end

    {value, rest}
  end

  defp scrub_class(value, allowed) when is_binary(value) and is_list(allowed) do
    tokens =
      value
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.filter(&(&1 in allowed))
      |> Enum.uniq()

    case tokens do
      [] -> nil
      _ -> {"class", Enum.join(tokens, " ")}
    end
  end

  defp scrub_class(_value, _allowed), do: nil

  defp emoji_img?(attributes) when is_list(attributes) do
    src = get_attribute(attributes, "src")

    has_emoji_class? =
      case get_attribute(attributes, "class") do
        "emoji" -> true
        _ -> false
      end

    alt_is_emoji? =
      case get_attribute(attributes, "alt") do
        alt when is_binary(alt) -> Regex.match?(@emoji_alt_regex, String.trim(alt))
        _ -> false
      end

    is_binary(src) and src != "" and (has_emoji_class? or alt_is_emoji?)
  end

  defp emoji_img?(_attributes), do: false

  defp ensure_img_class(attributes, class) when is_list(attributes) and is_binary(class) do
    case get_attribute(attributes, "class") do
      ^class -> attributes
      _ -> attributes ++ [{"class", class}]
    end
  end

  defp get_attribute(attributes, key) when is_list(attributes) and is_binary(key) do
    case Enum.find(attributes, fn {attr, _value} -> attr == key end) do
      {^key, value} -> value
      _ -> nil
    end
  end
end
