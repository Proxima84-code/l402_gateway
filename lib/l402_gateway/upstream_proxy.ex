defmodule L402Gateway.UpstreamProxy do
  def upstream_url do
    System.get_env("PYTHON_MCP_UPSTREAM_URL", "http://127.0.0.1:8001/mcp")
  end

  def fetch_upstream_tools do
    payload = %{"jsonrpc" => "2.0", "id" => "upstream_list", "method" => "tools/list"}

    case Req.post(upstream_url(), json: payload, headers: mcp_headers(), receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"result" => %{"tools" => tools}}}} when is_list(tools) ->
        tools

      _ ->
        []
    end
  end

  def forward_call(body_params) do
    case Req.post(upstream_url(), json: body_params, headers: mcp_headers(), receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, status, body}

      {:error, reason} ->
        {:error, 502, %{"error" => "Upstream FastMCP unavailable", "details" => inspect(reason)}}
    end
  end

  defp mcp_headers do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]
  end
end
