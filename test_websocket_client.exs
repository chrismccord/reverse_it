# WebSocket client test script
# Tests the WebSocket proxy by connecting through the proxy to the backend

defmodule WebSocketClient do
  require Logger

  def test do
    # Connect to proxy (port 4000) which will forward to backend (port 4001)
    {:ok, conn} = Mint.HTTP.connect(:http, "localhost", 4000)

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])

    # Wait for upgrade response
    conn = receive_upgrade(conn, ref)

    # Create WebSocket
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, :client, [])

    Logger.info("WebSocket connected through proxy!")

    # Send a text message
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, "Hello from client!"})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    Logger.info("Sent: 'Hello from client!'")

    # Receive messages
    {conn, websocket} = receive_messages(conn, websocket, ref)

    # Send another message
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, "Second message"})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    Logger.info("Sent: 'Second message'")

    # Receive more messages
    {conn, websocket} = receive_messages(conn, websocket, ref)

    # Close connection
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, :close)
    Mint.WebSocket.stream_request_body(conn, ref, data)

    Logger.info("Closed WebSocket connection")

    :ok
  end

  defp receive_upgrade(conn, ref) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

        Enum.reduce(responses, conn, fn
          {:status, ^ref, 101}, acc -> acc
          {:headers, ^ref, _headers}, acc -> acc
          {:done, ^ref}, acc -> acc
          _other, acc -> acc
        end)
    after
      5000 ->
        raise "Timeout waiting for WebSocket upgrade"
    end
  end

  defp receive_messages(conn, websocket, ref, count \\ 0) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, [{:data, ^ref, data}]} ->
            {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)

            Enum.each(frames, fn
              {:text, text} ->
                Logger.info("Received: #{text}")

              {:binary, binary} ->
                Logger.info("Received binary: #{byte_size(binary)} bytes")

              {:close, _code, _reason} ->
                Logger.info("Received close frame")

              other ->
                Logger.info("Received other frame: #{inspect(other)}")
            end)

            if count < 5 do
              receive_messages(conn, websocket, ref, count + 1)
            else
              {conn, websocket}
            end

          {:ok, conn, _other} ->
            if count < 5 do
              receive_messages(conn, websocket, ref, count + 1)
            else
              {conn, websocket}
            end

          :unknown ->
            if count < 5 do
              receive_messages(conn, websocket, ref, count + 1)
            else
              {conn, websocket}
            end
        end
    after
      2000 ->
        Logger.info("No more messages received")
        {conn, websocket}
    end
  end
end

# Run the test
WebSocketClient.test()
