defmodule L402Gateway.Router do
  use Plug.Router
  require Logger

  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason
  plug :dispatch

  @default_upstream "http://127.0.0.1:8000"

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match "/mcp/*path" do
    handle_l402_auth(conn, Enum.join(path, "/"))
  end

  match "/mcp" do
    handle_l402_auth(conn, "")
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not Found"}))
  end

  defp handle_l402_auth(conn, target_path) do
    case get_req_header(conn, "authorization") do
      ["L402 " <> token] ->
        verify_and_forward(conn, token, target_path)

      _ ->
        challenge_l402(conn)
    end
  end

  defp verify_and_forward(conn, token, target_path) do
    case String.split(token, ":") do
      [macaroon, preimage] when byte_size(preimage) > 0 ->
        case verify_payment(macaroon, preimage) do
          :ok ->
            forward_to_upstream(conn, target_path)

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(402, Jason.encode!(%{error: "Płatność nieprawidłowa", detail: reason}))
        end

      _ ->
        challenge_l402(conn)
    end
  end

  defp forward_to_upstream(conn, path) do
    base = System.get_env("UPSTREAM_MCP_URL", @default_upstream)
    clean_base = String.trim_trailing(base, "/")
    clean_path = String.trim_leading(path, "/")

    target_url =
      if clean_path == "" do
        clean_base
      else
        "#{clean_base}/#{clean_path}"
      end

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

    is_sse = String.contains?(path, "sse") or get_req_header(conn, "accept") == ["text/event-stream"]

    if is_sse do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)

      Finch.build(:get, full_url, headers)
      |> Finch.stream(L402Gateway.Finch, nil, fn
        {:status, _}, acc -> acc
        {:headers, _}, acc -> acc
        {:data, chunk}, acc ->
          chunk(conn, chunk)
          acc
      end)

      conn
    else
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
  end

  defp challenge_l402(conn) do
    lnbits_url = System.get_env("LNBITS_BASE_URL", "http://127.0.0.1:5000")
    lnbits_key = System.get_env("LNBITS_INVOICE_KEY", "0581f8ff22404f2189d8a89cc3a12c23")

    case Req.post("#{lnbits_url}/api/v1/payments",
           headers: [{"X-Api-Key", lnbits_key}, {"Content-Type", "application/json"}],
           json: %{out: false, amount: 5, memo: "L402 MCP Access"}
         ) do
      {:ok, %Req.Response{status: status, body: %{"payment_hash" => payment_hash, "payment_request" => invoice}}}
      when status in [200, 201] ->
        macaroon = Base.encode64("l402_hash:#{payment_hash}")

        conn
        |> put_resp_header("www-authenticate", ~s(L402 macaroon="#{macaroon}", invoice="#{invoice}"))
        |> put_resp_content_type("application/json")
        |> send_resp(402, Jason.encode!(%{error: "Payment Required", invoice: invoice}))

      other ->
        Logger.error("LNbits challenge error: #{inspect(other)}")
        send_resp(conn, 500, Jason.encode!(%{error: "Failed to generate Lightning Invoice"}))
    end
  end

  defp verify_payment(macaroon, preimage) do
    with {:ok, decoded} <- Base.decode64(macaroon),
         "l402_hash:" <> payment_hash <- decoded do
      lnbits_url = System.get_env("LNBITS_BASE_URL", "http://127.0.0.1:5000")
      lnbits_key = System.get_env("LNBITS_INVOICE_KEY", "0581f8ff22404f2189d8a89cc3a12c23")

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
end
