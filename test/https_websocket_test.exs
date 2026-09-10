defmodule ReverseIt.HTTPSWebSocketTest do
  use ExUnit.Case, async: true

  test "WebSocket schemes preserve the HTTP transport security" do
    for {scheme, expected} <- [http: :ws, ws: :ws, https: :wss, wss: :wss] do
      assert ReverseIt.Config.websocket_scheme(%ReverseIt.Config{scheme: scheme}) == expected
    end
  end

  for scheme <- ["https", "wss"] do
    @scheme scheme
    test "#{scheme} backend sends and receives WebSocket frames over TLS" do
      tls =
        :public_key.pkix_test_data(%{
          root: [key: {:rsa, 2048, 65537}],
          peer: [key: {:rsa, 2048, 65537}]
        })

      {:ok, listener} = :ssl.listen(0, [mode: :binary, active: false] ++ tls)
      {:ok, {_, port}} = :ssl.sockname(listener)
      on_exit(fn -> :ssl.close(listener) end)

      start_supervised!({Task,
       fn ->
         {:ok, socket} = :ssl.transport_accept(listener, 2_000)
         {:ok, socket} = :ssl.handshake(socket, 2_000)
         {:ok, request} = :ssl.recv(socket, 0, 2_000)
         [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
         accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

         :ok =
           :ssl.send(socket, [
             "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n",
             "Sec-WebSocket-Accept: ",
             Base.encode64(accept),
             "\r\n\r\n"
           ])

         {:ok, _client_frame} = :ssl.recv(socket, 0, 2_000)
         :ok = :ssl.send(socket, <<0x81, 5, "hello">>)
         # Keep the socket alive until the client has consumed the frame.
         {:error, :closed} = :ssl.recv(socket, 0, 2_000)
       end})

      config =
        ReverseIt.init(
          backend: "#{@scheme}://localhost:#{port}",
          name: ReverseIt.TestFinch,
          verify_tls: false
        )

      client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}
      assert {:ok, state, _headers} = ReverseIt.WebSocketHandshake.open(config, client, "/", "")

      try do
        assert {:ok, state} = ReverseIt.WebSocketProxy.handle_in({"hi", opcode: :text}, state)
        assert_receive {:ssl, _, _} = message, 2_000

        assert {:push, [{:text, "hello"}], _state} =
                 ReverseIt.WebSocketProxy.handle_info(message, state)
      after
        Mint.HTTP.close(state.conn)
      end
    end
  end
end
