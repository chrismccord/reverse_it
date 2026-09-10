defmodule ReverseIt.WebSocketHandshakeErrorTest do
  use ExUnit.Case, async: true

  test "invalid accept nonce returns the Mint error and closes the upstream socket" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

         :ok =
           :gen_tcp.send(
             socket,
             "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n" <>
               "Upgrade: websocket\r\nSec-WebSocket-Accept: invalid\r\n\r\n"
           )

         send(parent, {:upstream_closed, :gen_tcp.recv(socket, 0, 1_000)})
         :gen_tcp.close(socket)
       end}
    )

    config = ReverseIt.init(backend: "http://127.0.0.1:#{port}", name: ReverseIt.TestFinch)
    client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}

    assert {:error, :invalid_nonce} =
             ReverseIt.WebSocketHandshake.open(config, client, "/", "")

    assert_receive {:upstream_closed, {:error, :closed}}, 2_000
  end
end
