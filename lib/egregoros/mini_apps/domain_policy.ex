defmodule Egregoros.MiniApps.DomainPolicy do
  @moduledoc false

  @type options :: [allow: [String.t()], deny: [String.t()]]

  def allowed?(domain, opts) when is_binary(domain) and is_list(opts) do
    allow = Keyword.get(opts, :allow, [])
    deny = Keyword.get(opts, :deny, [])

    with {:ok, domain} <- normalize_domain(domain),
         :ok <- validate_patterns(allow),
         :ok <- validate_patterns(deny) do
      not matches_any?(domain, deny) and (allow == [] or matches_any?(domain, allow))
    else
      _ -> false
    end
  end

  def allowed?(_domain, _opts), do: false

  def validate_patterns(patterns) when is_list(patterns) do
    if Enum.all?(patterns, &valid_pattern?/1) do
      :ok
    else
      {:error, :invalid_domain_pattern}
    end
  end

  def validate_patterns(_patterns), do: {:error, :invalid_domain_pattern}

  def normalize_domain(domain) when is_binary(domain) do
    domain = domain |> String.trim() |> String.downcase()

    domain =
      if String.ends_with?(domain, ".") and not String.ends_with?(domain, "..") do
        String.slice(domain, 0, byte_size(domain) - 1)
      else
        domain
      end

    labels = String.split(domain, ".", trim: false)

    cond do
      domain == "" or byte_size(domain) > 253 ->
        {:error, :invalid_domain}

      length(labels) < 2 ->
        {:error, :invalid_domain}

      ip_literal?(domain) ->
        {:error, :invalid_domain}

      Enum.all?(labels, &valid_label?/1) ->
        {:ok, domain}

      true ->
        {:error, :invalid_domain}
    end
  end

  def normalize_domain(_domain), do: {:error, :invalid_domain}

  defp valid_pattern?("*." <> suffix), do: match?({:ok, _}, normalize_domain(suffix))
  defp valid_pattern?(pattern), do: match?({:ok, _}, normalize_domain(pattern))

  defp matches_any?(domain, patterns) do
    Enum.any?(patterns, &matches?(domain, &1))
  end

  defp matches?(domain, "*." <> suffix) do
    with {:ok, suffix} <- normalize_domain(suffix) do
      domain != suffix and String.ends_with?(domain, "." <> suffix)
    else
      _ -> false
    end
  end

  defp matches?(domain, pattern) do
    case normalize_domain(pattern) do
      {:ok, normalized} -> domain == normalized
      _ -> false
    end
  end

  defp valid_label?(label) when byte_size(label) in 1..63 do
    String.match?(label, ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/)
  end

  defp valid_label?(_label), do: false

  defp ip_literal?(domain) do
    case :inet.parse_address(String.to_charlist(domain)) do
      {:ok, _ip} -> true
      {:error, _reason} -> String.match?(domain, ~r/^\d+(?:\.\d+){1,3}$/)
    end
  end
end
