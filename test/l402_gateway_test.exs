defmodule L402GatewayTest do
  use ExUnit.Case
  doctest L402Gateway

  test "greets the world" do
    assert L402Gateway.hello() == :world
  end
end
