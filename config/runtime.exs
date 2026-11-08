import Config

if config_env() == :prod do
  config :l402_gateway,
    lnbits_url: System.get_env("LNBITS_BASE_URL", "http://127.0.0.1:5000"),
    lnbits_key: System.get_env("LNBITS_INVOICE_KEY", "0581f8ff22404f2189d8a89cc3a12c23"),
    upstream_url: System.get_env("UPSTREAM_MCP_URL", "http://127.0.0.1:8000")
end
