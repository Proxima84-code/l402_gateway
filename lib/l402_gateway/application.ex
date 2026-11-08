defmodule L402Gateway.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: L402Gateway.Finch},
      {Bandit, plug: L402Gateway.Router, port: 4002}
    ]

    opts = [strategy: :one_for_one, name: L402Gateway.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
