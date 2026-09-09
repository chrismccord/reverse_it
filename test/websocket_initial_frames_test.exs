defmodule ReverseIt.WebSocketInitialFramesTest do
  use ExUnit.Case, async: true

  alias ReverseIt.WebSocketProxy

  test "a frame received with the 101 response is forwarded at initialization" do
    state = open(<<0x81, 5, "hello">>)
    assert {:push, [{:text, "hello"}], state} = WebSocketProxy.init(state)
    assert {:ok, _state} = WebSocketProxy.init(state)
  end

  test "a frame split across the handshake and the next read retains decoder state" do
    state = open(<<0x81, 5, "hel">>)
    assert {:ok, state} = WebSocketProxy.init(state)

    assert {:push, [{:text, "hello"}], _state} =
             WebSocketProxy.handle_info({:tcp, Mint.HTTP.get_socket(state.conn), "lo"}, state)
  end

  test "initial data uses the same frame size limit as subsequent reads" do
    state = open(<<0x81, 5, "hello">>, max_websocket_frame_size: 4)
    assert {:stop, :backend_message_too_large, {1009, _reason}, _} = WebSocketProxy.init(state)
  end

  test "a handshake without initial frames initializes normally" do
    state = open("")
    assert {:ok, ^state} = WebSocketProxy.init(state)
  end

  defp open(initial_data, opts \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
         [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
         accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

         :ok =
           :gen_tcp.send(socket, [
             "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n",
             "Sec-WebSocket-Accept: ",
             Base.encode64(accept),
             "\r\n\r\n",
             initial_data
           ])

         {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
       end}
    )

    config =
      ReverseIt.init([backend: "http://127.0.0.1:#{port}", name: ReverseIt.TestFinch] ++ opts)

    client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}
    {:ok, state, _headers} = ReverseIt.WebSocketHandshake.open(config, client, "/", "")
    on_exit(fn -> Mint.HTTP.close(state.conn) end)
    state
  end
end
