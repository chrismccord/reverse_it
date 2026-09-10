defmodule ReverseIt.ServerPortsTest do
  use ExUnit.Case, async: true

  test "fixture ports belong to live, distinct listeners" do
    ports =
      for id <- 1..4 do
        start_supervised!(
          Supervisor.child_spec(
            {Bandit, plug: ReverseIt.TestBackend, port: 0, ip: {127, 0, 0, 1}},
            id: id
          )
        )
        |> TestHelper.listener_port()
      end

    ports = [
      Application.fetch_env!(:reverse_it, :test_backend_port),
      Application.fetch_env!(:reverse_it, :test_proxy_port)
      | ports
    ]

    assert length(Enum.uniq(ports)) == length(ports)

    for port <- ports do
      assert %{status: 200, body: "Hello from backend!"} =
               Req.get!("http://127.0.0.1:#{port}/hello", retry: false)
    end
  end
end
