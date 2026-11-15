defmodule L402Gateway.Lightning do
  @moduledoc """
  Tworzy faktury Lightning przez LNbits lub Phoenixd oraz generuje/weryfikuje tokeny L402.
  """

  def create_challenge(amount_sats \\ 1000, credits \\ 100) do
    with {:ok, %{payment_hash: payment_hash, bolt11: bolt11}} <- create_invoice(amount_sats, "Osmoza MCP (#{credits} reqs)") do
      macaroon = encode_macaroon(payment_hash, credits)
      {:ok, %{macaroon: macaroon, invoice: bolt11, amount_sats: amount_sats, credits: credits}}
    end
  end

  def verify_l402(auth_header) do
    with ["L402", credentials] <- String.split(auth_header, " ", parts: 2),
         [macaroon_b64, preimage_hex] <- String.split(credentials, ":", parts: 2),
         {:ok, %{payment_hash: expected_hash, credits: credits}} <- decode_and_verify_macaroon(macaroon_b64),
         {:ok, preimage_bin} <- Base.decode16(preimage_hex, case: :mixed),
         computed_hash <- Base.encode16(:crypto.hash(:sha256, preimage_bin), case: :lower),
         true <- Plug.Crypto.secure_compare(String.downcase(expected_hash), computed_hash) do
      {:ok, %{payment_hash: expected_hash, credits: credits}}
    else
      _ -> {:error, :invalid_l402}
    end
  end

  defp create_invoice(amount_sats, memo) do
    case System.get_env("LN_PROVIDER", "lnbits") do
      "phoenixd" ->
        url = System.fetch_env!("PHOENIXD_URL") <> "/createinvoice"
        pass = System.fetch_env!("PHOENIXD_PASSWORD")

        case Req.post(url, auth: {:basic, ":" <> pass}, form: [description: memo, amountSat: amount_sats]) do
          {:ok, %{status: 200, body: %{"paymentHash" => hash, "serialized" => bolt11}}} ->
            {:ok, %{payment_hash: hash, bolt11: bolt11}}

          err ->
            {:error, {:phoenixd_error, err}}
        end

      _ ->
        url = System.fetch_env!("LNBITS_URL") <> "/api/v1/payments"
        api_key = System.fetch_env!("LNBITS_INVOICE_KEY")

        case Req.post(url,
               headers: [{"x-api-key", api_key}],
               json: %{out: false, amount: amount_sats, memo: memo}
             ) do
          {:ok, %{status: 201, body: %{"payment_hash" => hash, "payment_request" => bolt11}}} ->
            {:ok, %{payment_hash: hash, bolt11: bolt11}}

          err ->
            {:error, {:lnbits_error, err}}
        end
    end
  end

  defp encode_macaroon(payment_hash, credits) do
    secret = System.get_env("L402_SECRET_KEY", "zmien_ten_sekret_produkcyjny")
    payload = "#{payment_hash}:#{credits}"
    sig = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
    Base.url_encode64("#{payload}:#{sig}", padding: false)
  end

  defp decode_and_verify_macaroon(macaroon_b64) do
    secret = System.get_env("L402_SECRET_KEY", "zmien_ten_sekret_produkcyjny")

    with {:ok, raw} <- Base.url_decode64(macaroon_b64, padding: false),
         [payment_hash, credits_str, sig] <- String.split(raw, ":", parts: 3),
         expected_sig <- :crypto.mac(:hmac, :sha256, secret, "#{payment_hash}:#{credits_str}") |> Base.encode16(case: :lower),
         true <- Plug.Crypto.secure_compare(sig, expected_sig),
         {credits, ""} <- Integer.parse(credits_str) do
      {:ok, %{payment_hash: payment_hash, credits: credits}}
    else
      _ -> {:error, :bad_macaroon}
    end
  end
end
