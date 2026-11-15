defmodule L402Gateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :l402_gateway,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {L402Gateway.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"}      ,
      {:req, "~> 0.5.0"},
      {:floki, "~> 0.36"},
      {:postgrex, "~> 0.19"}
 
]
  end
end
