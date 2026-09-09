defmodule ReverseIt.WebSocketRejectionHeadersTest do
  use ExUnit.Case, async: true

  test "an invalid rejection header block fails rather than becoming an empty header list" do
    assert {:error, :response_headers_too_large} = reject(32)
    assert_receive {:upstream_closed, {:error, :closed}}, 2_000
  end

  test "a valid rejection retains its status, body, and application headers" do
    assert {:reject, 403, headers, "denied"} = reject(1_024)
    assert {"x-denied", String.duplicate("x", 64)} in headers
    refute List.keymember?(headers, "sec-websocket-accept", 0)
    assert_receive {:upstream_closed, {:error, :closed}}, 2_000
  end

  defp reject(limit) do
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
           :gen_tcp.send(socket, [
             "HTTP/1.1 403 Forbidden\r\nContent-Length: 6\r\nX-Denied: ",
             String.duplicate("x", 64),
             "\r\nSec-WebSocket-Accept: unused\r\n\r\ndenied"
           ])

         send(parent, {:upstream_closed, :gen_tcp.recv(socket, 0, 1_000)})
         :gen_tcp.close(socket)
       end}
    )

    config =
      ReverseIt.init(
        backend: "http://127.0.0.1:#{port}",
        name: ReverseIt.TestFinch,
        max_response_header_bytes: limit
      )

    client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}
    ReverseIt.WebSocketHandshake.open(config, client, "/", "")
  end
end
