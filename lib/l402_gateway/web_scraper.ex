defmodule L402Gateway.WebScraper do
  @moduledoc """
  Pobiera stronę WWW, wycina zbędny HTML/JS/CSS i zwraca czysty Markdown
  z buforowaniem w ETS (ochrona marży przy powtarzalnych zapytaniach agentów).
  """

  @table :mcp_markdown_cache
  @default_ttl_seconds 3600
  @max_bytes 2_000_000

  def init_cache do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @spec fetch_clean_markdown(String.t(), keyword()) ::
          {:ok, %{markdown: String.t(), cache: :hit | :miss, title: String.t()}}
          | {:error, String.t()}
  def fetch_clean_markdown(raw_url, opts \\ []) do
    init_cache()
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    with {:ok, uri} <- validate_public_url(raw_url) do
      cache_key = URI.to_string(uri)
      now = System.system_time(:second)

      case lookup_fresh(cache_key, now) do
        {:ok, cached} ->
          {:ok, Map.put(cached, :cache, :hit)}

        :miss ->
          with {:ok, html} <- download_html(cache_key),
               {:ok, parsed} <- html_to_markdown(html, uri) do
            :ets.insert(@table, {cache_key, parsed, now + ttl})
            {:ok, Map.put(parsed, :cache, :miss)}
          end
      end
    end
  end

  defp lookup_fresh(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, data, expires_at}] when expires_at > now -> {:ok, data}
      [{^key, _data, _expired}] ->
        :ets.delete(@table, key)
        :miss
      [] -> :miss
    end
  end

  # Ochrona przed SSRF: zezwalamy wyłącznie na publiczne adresy HTTP/HTTPS
  defp validate_public_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "Dozwolone są wyłącznie protokoły http:// oraz https://"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "Nieprawidłowy adres URL"}

      blocked_host?(uri.host) ->
        {:error, "Dostęp do adresów lokalnych i prywatnych sieci jest zablokowany"}

      true ->
        {:ok, uri}
    end
  end

  defp validate_public_url(_), do: {:error, "Parametr 'url' musi być ciągiem znaków"}

  defp blocked_host?(host) do
    lower = String.downcase(host)

    lower in ["localhost", "0.0.0.0", "127.0.0.1", "::1"] or
      String.ends_with?(lower, ".local") or
      String.ends_with?(lower, ".internal") or
      private_ip?(lower)
  end

  defp private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {127, _, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, _} -> false
      {:error, _} -> false
    end
  end

  defp download_html(url) do
    req_opts = [
      headers: [
        {"user-agent", "OsmozaMCPBot/1.0 (+https://osmoza-edge.pages.dev)"},
        {"accept", "text/html,application/xhtml+xml"}
      ],
      receive_timeout: 10_000,
      max_redirects: 3
    ]

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        if byte_size(body) > @max_bytes do
          {:ok, binary_part(body, 0, @max_bytes)}
        else
          {:ok, body}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "Serwer docelowy zwrócił kod HTTP #{status}"}

      {:error, reason} ->
        {:error, "Błąd połączenia ze stroną: #{inspect(reason)}"}
    end
  end

  defp html_to_markdown(html, base_uri) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        title =
          doc
          |> Floki.find("title")
          |> Floki.text()
          |> String.trim()

        # Wycinamy elementy szumu (skrypty, style, nawigacje, stopki, formularze)
        cleaned =
          doc
          |> Floki.filter_out("script, style, noscript, iframe, svg, nav, footer, header, aside, form")

        # Preferujemy główną treść artykułu/dokumentacji, jeśli istnieje
        root =
          case Floki.find(cleaned, "main, article, [role='main']") do
            [] -> Floki.find(cleaned, "body")
            nodes -> nodes
          end

        markdown_body =
          root
          |> Enum.map_join("\n\n", &node_to_md(&1, base_uri))
          |> normalize_whitespace()

        header = if title != "", do: "# #{title}\nSource: #{URI.to_string(base_uri)}\n\n", else: ""
        {:ok, %{title: title, markdown: header <> markdown_body}}

      {:error, _} ->
        {:error, "Nie udało się sparsować dokumentu HTML"}
    end
  end

  defp node_to_md(text, _base_uri) when is_binary(text) do
    String.replace(text, ~r/\s+/, " ")
  end

  defp node_to_md({tag, attrs, children}, base_uri) do
    inner = Enum.map_join(children, "", &node_to_md(&1, base_uri)) |> String.trim()

    case tag do
      "h1" -> "\n\n# #{inner}\n\n"
      "h2" -> "\n\n## #{inner}\n\n"
      "h3" -> "\n\n### #{inner}\n\n"
      "h4" -> "\n\n#### #{inner}\n\n"
      "p" -> "\n\n#{inner}\n\n"
      "br" -> "\n"
      "hr" -> "\n\n---\n\n"
      "strong" -> "**#{inner}**"
      "b" -> "**#{inner}**"
      "em" -> "*#{inner}*"
      "i" -> "*#{inner}*"
      "code" -> "`#{inner}`"
      "pre" -> "\n\n```\n#{Floki.text({tag, attrs, children}) |> String.trim()}\n```\n\n"
      "blockquote" -> "\n\n> #{String.replace(inner, "\n", "\n> ")}\n\n"
      "li" -> "\n- #{inner}"
      "ul" -> "\n#{inner}\n"
      "ol" -> "\n#{inner}\n"
      "a" ->
        href = List.keyfind(attrs, "href", 0) |> elem_or_nil()
        resolved = resolve_url(href, base_uri)
        if inner == "" or is_nil(resolved), do: inner, else: "[#{inner}](#{resolved})"
      _ -> inner
    end
  end

  defp node_to_md(_, _), do: ""

  defp elem_or_nil({_, val}), do: val
  defp elem_or_nil(_), do: nil

  defp resolve_url(nil, _base), do: nil
  defp resolve_url("#" <> _, _base), do: nil
  defp resolve_url("javascript:" <> _, _base), do: nil

  defp resolve_url(href, base_uri) do
    base_uri |> URI.merge(String.trim(href)) |> URI.to_string()
  rescue
    _ -> nil
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
