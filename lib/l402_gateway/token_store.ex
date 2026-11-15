defmodule L402Gateway.TokenStore do
  use GenServer
  require Logger

  @table :osmoza_tokens
  @price_per_req_pln 0.12
  @origin_cost_per_miss 0.024
  @payment_fee_rate 0.015
  @fixed_infra_opex_pln 72.00

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_state) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{pg: nil}, {:continue, :connect_db}}
  end

  def handle_continue(:connect_db, state) do
    conn = start_pg_connection()
    if conn, do: load_tokens_from_db(conn)
    {:noreply, %{state | pg: conn}}
  end

  def valid?(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{^token, credits}] when credits > 0 -> true
      _ -> false
    end
  end

  def consume_credit(token, meta \\ %{}) do
    case :ets.lookup(@table, token) do
      [{^token, credits}] when credits > 0 ->
        new_credits = :ets.update_counter(@table, token, {2, -1})
        GenServer.cast(__MODULE__, {:record_usage, token, new_credits, meta})
        {:ok, new_credits}

      _ ->
        {:error, :insufficient_credits}
    end
  end

  def consume_l402(payment_hash, initial_credits, meta \\ %{}) do
    key = "l402_" <> payment_hash

    case :ets.lookup(@table, key) do
      [] ->
        remaining = max(initial_credits - 1, 0)
        :ets.insert(@table, {key, remaining})
        GenServer.cast(__MODULE__, {:persist_token, key, key, initial_credits})
        GenServer.cast(__MODULE__, {:record_usage, key, remaining, meta})
        {:ok, remaining}

      [{^key, credits}] when credits > 0 ->
        new_credits = :ets.update_counter(@table, key, {2, -1})
        GenServer.cast(__MODULE__, {:record_usage, key, new_credits, meta})
        {:ok, new_credits}

      _ ->
        {:error, :insufficient_credits}
    end
  end

  def issue_for_session(session_id, credits \\ 1000) do
    token = "mcp_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :ets.insert(@table, {token, credits})
    GenServer.cast(__MODULE__, {:persist_token, token, session_id, credits})
    token
  end

  def get_live_stats, do: GenServer.call(__MODULE__, :get_live_stats)

  def handle_call(:get_live_stats, _from, %{pg: nil} = state) do
    {:reply, default_stats(false), state}
  end

  def handle_call(:get_live_stats, _from, %{pg: pg} = state) do
    query = ~S"""
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE "cacheStatus" = 'HIT'),
           COUNT(*) FILTER (WHERE "cacheStatus" = 'MISS'),
           COALESCE(AVG("latencyMs") FILTER (WHERE "cacheStatus" = 'HIT'), 20.0)
    FROM "UsageLog"
    """

    stats =
      case Postgrex.query(pg, query, []) do
        {:ok, %Postgrex.Result{rows: [[total, hits, misses, avg_ms]]}} when total > 0 ->
          rev = total * @price_per_req_pln
          opex = @fixed_infra_opex_pln + rev * @payment_fee_rate + misses * @origin_cost_per_miss
          ebitda = rev - opex

          %{
            db_connected: true,
            total_requests: total,
            cache_hits: hits,
            cache_misses: misses,
            hit_rate_pct: Float.round(hits / total * 100, 1),
            avg_hit_ms: Float.round(avg_ms * 1.0, 1),
            gross_revenue_pln: Float.round(rev, 2),
            opex_pln: Float.round(opex, 2),
            ebitda_pln: Float.round(ebitda, 2),
            ros_pct: Float.round(ebitda / rev * 100, 1),
            saved_vs_no_cache_pln: Float.round(hits * @origin_cost_per_miss, 2)
          }

        _ ->
          default_stats(true)
      end

    {:reply, stats, state}
  end

  def handle_cast({:persist_token, _, _, _}, %{pg: nil} = state), do: {:noreply, state}

  def handle_cast({:persist_token, token, session_id, credits}, %{pg: pg} = state) do
    id = "tok_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    sql = ~S"""
    INSERT INTO "ApiToken" ("id", "token", "stripeSessionId", "creditsRemaining", "totalRequests", "createdAt")
    VALUES ($1, $2, $3, $4, 0, NOW())
    ON CONFLICT ("stripeSessionId") DO NOTHING
    """

    Postgrex.query(pg, sql, [id, token, session_id, credits])
    {:noreply, state}
  end

  def handle_cast({:record_usage, _, _, _}, %{pg: nil} = state), do: {:noreply, state}

  def handle_cast({:record_usage, token, new_credits, meta}, %{pg: pg} = state) do
    update_sql = ~S"""
    UPDATE "ApiToken"
    SET "creditsRemaining" = $1, "totalRequests" = "totalRequests" + 1
    WHERE "token" = $2
    """

    Postgrex.query(pg, update_sql, [new_credits, token])

    log_id = "log_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    insert_sql = ~S"""
    INSERT INTO "UsageLog" ("id", "tokenId", "toolName", "targetUrl", "cacheStatus", "latencyMs", "createdAt")
    VALUES ($1, $2, $3, $4, $5, $6, NOW())
    """

    Postgrex.query(pg, insert_sql, [
      log_id,
      token,
      Map.get(meta, :tool, "fetch_clean_markdown"),
      Map.get(meta, :url, ""),
      Map.get(meta, :cache, "MISS"),
      Map.get(meta, :latency_ms, 0.0)
    ])

    {:noreply, state}
  end

  defp default_stats(db_ok) do
    %{
      db_connected: db_ok,
      total_requests: 0,
      hit_rate_pct: 82.0,
      avg_hit_ms: 20.0,
      gross_revenue_pln: 0.0,
      opex_pln: @fixed_infra_opex_pln,
      ebitda_pln: 0.0,
      ros_pct: 94.8,
      saved_vs_no_cache_pln: 0.0
    }
  end

  defp start_pg_connection do
    raw =
      [System.get_env("DIRECT_DATABASE_URL"), System.get_env("DATABASE_URL")]
      |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))

    with url when is_binary(url) <- raw,
         clean = url |> String.trim() |> String.trim("\"") |> String.trim("'"),
         %URI{host: host} = uri when is_binary(host) and host != "" <- URI.parse(clean) do
      [user, pass] = String.split(uri.userinfo || ":", ":", parts: 2)
      db = String.trim_leading(uri.path || "/postgres", "/")

      Process.flag(:trap_exit, true)

      case Postgrex.start_link(
             hostname: host,
             port: uri.port || 5432,
             username: user,
             password: pass,
             database: db,
             ssl: [verify: :verify_none, server_name_indication: String.to_charlist(host)],
             show_sensitive_data_on_connection_error: true,
             connect_timeout: 15_000,
             timeout: 15_000,
             backoff_type: :stop
           ) do
        {:ok, pid} ->
          Logger.info("Połączono z Prisma Postgres (#{host})")
          pid

        {:error, reason} ->
          Logger.error("Błąd połączenia z Prisma Postgres: #{inspect(reason)}")
          nil
      end
    else
      _ ->
        Logger.warning("Brak poprawnego DATABASE_URL - działa w trybie RAM (ETS)")
        nil
    end
  end

  defp load_tokens_from_db(pg) do
    sql = ~S"""
    SELECT "token", "creditsRemaining" FROM "ApiToken" WHERE "creditsRemaining" > 0
    """

    case Postgrex.query(pg, sql, []) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.each(rows, fn [t, c] -> :ets.insert(@table, {t, c}) end)
        Logger.info("Wczytano #{length(rows)} aktywnych tokenów z Prisma Postgres do ETS")

      _ ->
        :ok
    end
  end
end
