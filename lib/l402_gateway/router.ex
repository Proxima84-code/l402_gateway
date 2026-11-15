defmodule L402Gateway.Router do
  use Plug.Router
  require Logger

  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    body_reader: {L402Gateway.RawBodyReader, :read_body, []},
    json_decoder: Jason
  plug :dispatch

  @default_upstream "http://127.0.0.1:8001/mcp"

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match "/mcp/*path" do
    handle_l402_auth(conn, Enum.join(path, "/"))
  end

  post "/webhook" do
    raw_body = conn.assigns[:raw_body] || ""
    sig_header = List.first(get_req_header(conn, "stripe-signature")) || ""
    secret = System.get_env("STRIPE_WEBHOOK_SECRET", "")

    case verify_stripe_signature(raw_body, sig_header, secret) do
      :ok ->
        event_type = conn.body_params["type"]
        Logger.info("Odebrano zweryfikowane zdarzenie Stripe: #{event_type}")

        if event_type == "checkout.session.completed" do
          session_id = get_in(conn.body_params, ["data", "object", "id"]) || "sess_#{System.system_time(:second)}"
          token = L402Gateway.TokenStore.issue_for_session(session_id)
          Logger.info("Wygenerowano nowy token dostępu MCP dla sesji #{session_id}: #{token}")
        end

        send_resp(conn, 200, Jason.encode!(%{received: true}))

      {:error, reason} ->
        Logger.warning("Odrzucono webhook Stripe: #{inspect(reason)}")
        send_resp(conn, 400, Jason.encode!(%{error: "Invalid signature"}))
    end
  end

  get "/api/stats" do
    stats = L402Gateway.TokenStore.get_live_stats()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(stats))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not Found"}))
  end

  # Darmowy handshake MCP (initialize, notifications/initialized, tools/list, ping)
  defp handle_l402_auth(%Plug.Conn{method: "POST", body_params: %{"method" => method}} = conn, "")
       when method in ["initialize", "notifications/initialized", "tools/list", "ping"] do
    handle_local_mcp(conn)
  end

  defp handle_l402_auth(conn, target_path) do
    case get_req_header(conn, "authorization") do
      ["L402 " <> token] ->
        verify_and_forward(conn, token, target_path)

      ["Bearer " <> bearer_token] ->
        token = String.trim(bearer_token)

        if token != "" and L402Gateway.TokenStore.valid?(token) do
          dispatch_mcp_or_upstream(conn, target_path)
        else
          challenge_l402(conn)
        end

      _ ->
        challenge_l402(conn)
    end
  end

  defp verify_and_forward(conn, token, target_path) do
    case String.split(token, ":") do
      [macaroon, preimage] when byte_size(preimage) > 0 ->
        case verify_payment(macaroon, preimage) do
          :ok ->
            dispatch_mcp_or_upstream(conn, target_path)

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(402, Jason.encode!(%{error: "Płatność nieprawidłowa", detail: reason}))
        end

      _ ->
        challenge_l402(conn)
    end
  end

  defp dispatch_mcp_or_upstream(conn, "") when conn.method == "POST" do
    handle_local_mcp(conn)
  end

  defp dispatch_mcp_or_upstream(conn, target_path) do
    forward_to_upstream(conn, target_path)
  end

  defp handle_local_mcp(conn) do
    case conn.body_params do
      %{"method" => "initialize", "id" => id} ->
        send_json_rpc(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "osmoza-l402-gateway", "version" => "1.0.0"}
          }
        })

      %{"method" => "notifications/initialized"} ->
        send_resp(conn, 202, "")

      %{"method" => "ping", "id" => id} ->
        send_json_rpc(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

      %{"method" => "tools/list", "id" => id} ->
        local_tools = [
          %{
            "name" => "fetch_clean_markdown",
            "description" =>
              "Fetches any public web page, strips HTML/JS/ads/navigation, and returns clean, token-dense Markdown with edge caching.",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{
                "url" => %{
                  "type" => "string",
                  "description" => "Full HTTP or HTTPS URL of the page to convert to Markdown"
                }
              },
              "required" => ["url"]
            }
          }
        ]

        upstream_tools = L402Gateway.UpstreamProxy.fetch_upstream_tools()

        send_json_rpc(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "tools" => local_tools ++ upstream_tools
          }
        })

      %{"method" => "tools/call", "id" => id, "params" => %{"name" => "fetch_clean_markdown"} = params} ->
        send_json_rpc(conn, handle_local_scraper(id, params))

      %{"method" => "tools/call", "id" => id} = body_params ->
        case L402Gateway.UpstreamProxy.forward_call(body_params) do
          {:ok, upstream_resp} ->
            send_json_rpc(conn, upstream_resp)

          {:error, status, err_body} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(status, Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{"code" => -32000, "message" => "Upstream FastMCP error", "data" => err_body}
            }))
        end

      %{"id" => id} ->
        send_json_rpc(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        })

      _ ->
        send_resp(conn, 400, Jason.encode!(%{error: "Invalid JSON-RPC payload"}))
    end
  end

  defp send_json_rpc(conn, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  defp handle_local_scraper(id, %{"arguments" => %{"url" => url}}) do
    start_us = System.monotonic_time(:microsecond)

    case L402Gateway.WebScraper.fetch_clean_markdown(url) do
      {:ok, %{markdown: md, cache: cache_status}} ->
        elapsed_ms = Float.round((System.monotonic_time(:microsecond) - start_us) / 1000, 2)
        meta_banner = "_[Osmoza Edge Cache: #{String.upcase(to_string(cache_status))} | Latency: #{elapsed_ms} ms]_\n\n"

        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [
              %{"type" => "text", "text" => meta_banner <> md}
            ],
            "isError" => false
          }
        }

      {:error, reason} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [
              %{"type" => "text", "text" => "Błąd pobierania strony: #{reason}"}
            ],
            "isError" => true
          }
        }
    end
  end

  defp handle_local_scraper(id, _other) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32602, "message" => "Missing 'url' argument for fetch_clean_markdown"}
    }
  end

  defp forward_to_upstream(conn, path) do
    base = System.get_env("PYTHON_MCP_UPSTREAM_URL", System.get_env("UPSTREAM_MCP_URL", @default_upstream))
    clean_base = String.trim_trailing(base, "/")
    clean_path = String.trim_leading(path, "/")

    target_url = if clean_path == "", do: clean_base, else: "#{clean_base}/#{clean_path}"
    query_str = if conn.query_string != "", do: "?#{conn.query_string}", else: ""
    full_url = target_url <> query_str

    headers =
      conn.req_headers
      |> Enum.reject(fn {k, _} -> k in ["host", "authorization", "content-length", "connection"] end)

    req_body =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> nil
        empty when empty == %{} -> nil
        params -> Jason.encode!(params)
      end

    headers_map =
      headers
      |> Enum.into(%{})
      |> Map.put_new("content-type", "application/json")

    req_options = [
      method: String.to_atom(String.downcase(conn.method)),
      url: full_url,
      headers: headers_map,
      retry: false,
      receive_timeout: 30_000
    ]

    req_options = if req_body, do: Keyword.put(req_options, :body, req_body), else: req_options

    case Req.request(req_options) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        response_conn =
          Enum.reduce(resp_headers, conn, fn {k, v}, acc ->
            if k in ["transfer-encoding", "content-length", "connection"] do
              acc
            else
              put_resp_header(acc, k, List.to_string(List.wrap(v)))
            end
          end)

        serialized_body =
          cond do
            is_binary(resp_body) -> resp_body
            is_map(resp_body) or is_list(resp_body) -> Jason.encode!(resp_body)
            true -> to_string(resp_body)
          end

        send_resp(response_conn, status, serialized_body)

      {:error, err} ->
        Logger.error("Błąd przekazywania do upstreamu: #{inspect(err)}")
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{error: "Bad Gateway", detail: "FastMCP upstream unreachable"}))
    end
  end

  defp challenge_l402(conn) do
    {lnbits_url, lnbits_key} = lnbits_config()
    price_sats = String.to_integer(System.get_env("L402_PRICE_SATS", "50"))

    case Req.post("#{lnbits_url}/api/v1/payments",
           headers: [{"X-Api-Key", lnbits_key}, {"Content-Type", "application/json"}],
           json: %{out: false, amount: price_sats, memo: "Osmoza L402 MCP Access"}
         ) do
      {:ok, %Req.Response{status: status, body: %{"payment_hash" => payment_hash, "payment_request" => invoice}}}
      when status in [200, 201] ->
        macaroon = sign_macaroon(payment_hash)

        conn
        |> put_resp_header("www-authenticate", ~s(L402 macaroon="#{macaroon}", invoice="#{invoice}"))
        |> put_resp_content_type("application/json")
        |> send_resp(402, Jason.encode!(%{error: "Payment Required", invoice: invoice}))

      other ->
        Logger.error("LNbits challenge error: #{inspect(other)}")
        send_resp(conn, 500, Jason.encode!(%{error: "Failed to generate Lightning Invoice"}))
    end
  end

  defp verify_payment(macaroon, _preimage) do
    with {:ok, payment_hash} <- verify_macaroon_signature(macaroon) do
      {lnbits_url, lnbits_key} = lnbits_config()

      case Req.get("#{lnbits_url}/api/v1/payments/#{payment_hash}",
             headers: [{"X-Api-Key", lnbits_key}]
           ) do
        {:ok, %Req.Response{status: 200, body: %{"paid" => true}}} ->
          :ok

        {:ok, %Req.Response{status: 200, body: %{"details" => %{"pending" => false}}}} ->
          :ok

        other ->
          Logger.warning("Weryfikacja płatności nie powiodła się: #{inspect(other)}")
          {:error, :unpaid}
      end
    else
      _ -> {:error, :invalid_macaroon}
    end
  end

  defp sign_macaroon(payment_hash) do
    secret = System.get_env("L402_SECRET_KEY", "")
    sig = :crypto.mac(:hmac, :sha256, secret, payment_hash) |> Base.encode16(case: :lower)
    Base.encode64("l402_hash:#{payment_hash}:#{sig}")
  end

  defp verify_macaroon_signature(macaroon) do
    secret = System.get_env("L402_SECRET_KEY", "")

    with {:ok, decoded} <- Base.decode64(macaroon),
         ["l402_hash", payment_hash, sig] <- String.split(decoded, ":", parts: 3) do
      expected = :crypto.mac(:hmac, :sha256, secret, payment_hash) |> Base.encode16(case: :lower)
      if Plug.Crypto.secure_compare(expected, sig), do: {:ok, payment_hash}, else: :error
    else
      _ -> :error
    end
  end

  defp lnbits_config do
    url = System.get_env("LNBITS_URL") || System.get_env("LNBITS_BASE_URL") || "http://127.0.0.1:5000"
    key = System.get_env("LNBITS_API_KEY") || System.get_env("LNBITS_INVOICE_KEY") || ""
    {String.trim_trailing(url, "/"), key}
  end

  defp verify_stripe_signature(_payload, "", _secret), do: {:error, :missing_signature}
  defp verify_stripe_signature(_payload, _header, ""), do: {:error, :missing_secret}

  defp verify_stripe_signature(payload, sig_header, secret) do
    parts =
      sig_header
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.into(%{}, fn [k, v] -> {k, v} end)

    with %{"t" => timestamp, "v1" => signature} <- parts do
      signed_payload = "#{timestamp}.#{payload}"

      expected_sig =
        :crypto.mac(:hmac, :sha256, secret, signed_payload)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected_sig, signature) do
        :ok
      else
        {:error, :signature_mismatch}
      end
    else
      _ -> {:error, :malformed_header}
    end
  end
end
