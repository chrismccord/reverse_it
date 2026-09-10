defmodule ReverseIt.WebSocketRejectionBodyLimitTest do
  use ExUnit.Case, async: true

  test "default limit bounds rejection bodies even with unlimited ordinary HTTP responses" do
    assert {:error, :backend_response_too_large} = reject(65_537, [])
  end

  test "chunked rejection bodies are bounded without Content-Length" do
    assert {:error, :backend_response_too_large} =
             reject(17, [max_websocket_upgrade_response_body_size: 16], :chunked)
  end

  test "a body exactly at the limit is preserved" do
    assert {:reject, 403, _headers, "xxxxxxxxxxxxxxxx"} =
             reject(16, max_websocket_upgrade_response_body_size: 16)
  end

  test "a smaller general response body limit still applies" do
    assert {:error, :backend_response_too_large} =
             reject(9, max_websocket_upgrade_response_body_size: 16, max_response_body_size: 8)
  end

  test "zero permits empty rejections but not nonempty ones" do
    assert {:reject, 403, _headers, ""} = reject(0, max_websocket_upgrade_response_body_size: 0)

    assert {:error, :backend_response_too_large} =
             reject(1, max_websocket_upgrade_response_body_size: 0)
  end

  test "the buffer cap must be finite and non-negative" do
    for limit <- [:infinity, -1, nil, "1024"] do
      assert {:error, "max_websocket_upgrade_response_body_size must be a non-negative integer"} =
               ReverseIt.Config.parse(
                 backend: "http://localhost",
                 name: ReverseIt.TestFinch,
                 max_websocket_upgrade_response_body_size: limit
               )
    end
  end

  defp reject(size, opts, framing \\ :length) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    ref = make_ref()

    start_supervised!(
      Supervisor.child_spec(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
           body = String.duplicate("x", size)

           response =
             case framing do
               :length ->
                 ["Content-Length: #{size}\r\n\r\n", body]

               :chunked ->
                 [
                   "Transfer-Encoding: chunked\r\n\r\n",
                   Integer.to_string(size, 16),
                   "\r\n",
                   body,
                   "\r\n0\r\n\r\n"
                 ]
             end

           :ok = :gen_tcp.send(socket, ["HTTP/1.1 403 Forbidden\r\n", response])
           send(parent, {ref, :gen_tcp.recv(socket, 0, 2_000)})
           :gen_tcp.close(socket)
         end},
        id: ref
      )
    )

    config =
      ReverseIt.init([backend: "http://127.0.0.1:#{port}", name: ReverseIt.TestFinch] ++ opts)

    client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}
    result = ReverseIt.WebSocketHandshake.open(config, client, "/", "")
    assert_receive {^ref, {:error, :closed}}, 3_000
    result
  end
end
