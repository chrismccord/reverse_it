defmodule ReverseItTest do
  use ExUnit.Case
  doctest ReverseIt

  # Helper functions to get dynamic URLs and ports at runtime
  defp proxy_url, do: "http://localhost:#{Application.get_env(:reverse_it, :test_proxy_port)}"
  defp backend_url, do: "http://localhost:#{Application.get_env(:reverse_it, :test_backend_port)}"
  defp proxy_port, do: Application.get_env(:reverse_it, :test_proxy_port)
  defp backend_port, do: Application.get_env(:reverse_it, :test_backend_port)

  describe "HTTP Proxy" do
    test "proxies simple GET request" do
      response = Req.get!("#{proxy_url()}/hello")
      assert response.status == 200
      assert response.body == "Hello from backend!"
    end

    test "proxies JSON API endpoint" do
      response = Req.get!("#{proxy_url()}/api/status")
      assert response.status == 200
      assert is_map(response.body)
      assert response.body["status"] == "ok"
      assert response.body["server"] == "backend"
      assert Map.has_key?(response.body, "timestamp")
    end

    test "proxies POST request with body" do
      response = Req.post!("#{proxy_url()}/echo", body: "test data")
      assert response.status == 200
      assert is_map(response.body)
      assert response.body["echo"] == "test data"
    end

    test "forwards headers correctly" do
      response = Req.get!("#{proxy_url()}/headers")
      assert response.status == 200
      headers = response.body["headers"]

      # Backend should receive host header pointing to backend
      assert headers["host"] == "localhost:#{backend_port()}"

      # Should have X-Forwarded headers
      assert Map.has_key?(headers, "x-forwarded-for")
      assert Map.has_key?(headers, "x-forwarded-proto")
      assert Map.has_key?(headers, "x-forwarded-host")
    end

    test "handles 404 from backend" do
      response = Req.get!("#{proxy_url()}/nonexistent", retry: false)
      assert response.status == 404
    end

    test "backend is directly accessible for comparison" do
      response = Req.get!("#{backend_url()}/hello")
      assert response.status == 200
      assert response.body == "Hello from backend!"
    end
  end

  describe "WebSocket Proxy" do
    @tag :websocket
    test "detects WebSocket upgrade request" do
      # Connect directly to proxy with WebSocket upgrade headers
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())

      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])

      # We should get a response (even if upgrade fails, we get a response)
      assert_receive message, 1000

      case Mint.WebSocket.stream(conn, message) do
        {:ok, _conn, responses} ->
          # Should have status response
          assert Enum.any?(responses, fn
                   {:status, ^ref, _status} -> true
                   _ -> false
                 end)

        :unknown ->
          flunk("Expected Mint message but got unknown")
      end

      Mint.HTTP.close(conn)
    end

    @tag :websocket
    test "proxies WebSocket messages bidirectionally" do
      # Connect to proxy which will forward to backend
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])

      # Wait for upgrade
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5000)

      # Send message
      {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, "Hello from test!"})
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

      # Receive response (backend echoes with prefix)
      {conn, websocket, received_data} = receive_ws_data(conn, websocket, ref, 2000)

      # Decode and verify
      {:ok, _websocket, frames} = Mint.WebSocket.decode(websocket, received_data)

      text_frames =
        Enum.filter(frames, fn
          {:text, _} -> true
          _ -> false
        end)

      assert length(text_frames) > 0
      {:text, text} = hd(text_frames)
      assert text == "Backend echo: Hello from test!"

      # Send another message to verify continued operation
      {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, "Second message"})
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

      # Receive second response
      {conn, websocket, received_data} = receive_ws_data(conn, websocket, ref, 2000)
      {:ok, _websocket, frames} = Mint.WebSocket.decode(websocket, received_data)

      text_frames =
        Enum.filter(frames, fn
          {:text, _} -> true
          _ -> false
        end)

      assert length(text_frames) > 0
      {:text, text} = hd(text_frames)
      assert text == "Backend echo: Second message"

      # Close connection
      {:ok, _websocket, data} = Mint.WebSocket.encode(websocket, :close)
      Mint.WebSocket.stream_request_body(conn, ref, data)
      Mint.HTTP.close(conn)
    end

    @tag :websocket
    test "proxies binary WebSocket frames" do
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5000)

      # Send binary data
      binary_data = <<1, 2, 3, 4, 5>>
      {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:binary, binary_data})
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

      # Receive echoed binary
      {conn, websocket, received_data} = receive_ws_data(conn, websocket, ref, 2000)
      {:ok, _websocket, frames} = Mint.WebSocket.decode(websocket, received_data)

      # Backend echoes binary frames as-is
      assert {:binary, ^binary_data} = hd(frames)

      Mint.HTTP.close(conn)
    end

    @tag :websocket
    test "proxies ping/pong frames" do
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5000)

      # Send ping
      {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:ping, "test"})
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

      # Should receive pong back
      {_conn, _websocket, received_data} = receive_ws_data(conn, websocket, ref, 2000)
      {:ok, _websocket, frames} = Mint.WebSocket.decode(websocket, received_data)

      # Backend should respond with pong
      assert Enum.any?(frames, fn
               {:pong, "test"} -> true
               _ -> false
             end)

      Mint.HTTP.close(conn)
    end

    @tag :websocket
    test "handles multiple simultaneous WebSocket connections" do
      # Test that two independent connections can exist simultaneously
      # We'll test them sequentially to avoid message ordering issues

      # Create first connection
      {:ok, conn1} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn1, ref1} = Mint.WebSocket.upgrade(:ws, conn1, "/ws", [])
      {:ok, conn1, websocket1} = wait_for_ws_upgrade(conn1, ref1, 5000)

      # Create second connection while first is still open
      {:ok, conn2} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn2, ref2} = Mint.WebSocket.upgrade(:ws, conn2, "/ws", [])
      {:ok, conn2, websocket2} = wait_for_ws_upgrade(conn2, ref2, 5000)

      # Both connections established - now test each independently
      # Test conn1
      {:ok, websocket1, data1} = Mint.WebSocket.encode(websocket1, {:text, "From conn1"})
      {:ok, conn1} = Mint.WebSocket.stream_request_body(conn1, ref1, data1)
      {_conn1, _websocket1, received1} = receive_ws_data(conn1, websocket1, ref1, 5000)
      {:ok, _websocket1, frames1} = Mint.WebSocket.decode(websocket1, received1)

      {:text, text1} =
        hd(
          Enum.filter(frames1, fn
            {:text, _} -> true
            _ -> false
          end)
        )

      assert text1 == "Backend echo: From conn1"

      # Test conn2
      {:ok, websocket2, data2} = Mint.WebSocket.encode(websocket2, {:text, "From conn2"})
      {:ok, conn2} = Mint.WebSocket.stream_request_body(conn2, ref2, data2)
      {_conn2, _websocket2, received2} = receive_ws_data(conn2, websocket2, ref2, 5000)
      {:ok, _websocket2, frames2} = Mint.WebSocket.decode(websocket2, received2)

      {:text, text2} =
        hd(
          Enum.filter(frames2, fn
            {:text, _} -> true
            _ -> false
          end)
        )

      assert text2 == "Backend echo: From conn2"

      Mint.HTTP.close(conn1)
      Mint.HTTP.close(conn2)
    end

    @tag :websocket
    test "handles large WebSocket messages" do
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5000)

      # Send a large message (10KB to avoid fragmentation issues in test)
      large_text = String.duplicate("A", 10_000)
      {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, large_text})
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

      # Receive echoed large message (may come in multiple data chunks)
      messages = collect_messages(conn, websocket, ref, [], 1, 5000)

      assert length(messages) > 0
      text = hd(messages)
      assert String.starts_with?(text, "Backend echo: ")
      assert String.length(text) > 10_000

      Mint.HTTP.close(conn)
    end

    @tag :websocket
    test "handles rapid successive messages" do
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5000)

      # Send 10 messages rapidly without waiting for responses
      messages = for i <- 1..10, do: "Message #{i}"

      {conn, websocket} =
        Enum.reduce(messages, {conn, websocket}, fn msg, {c, ws} ->
          {:ok, ws, data} = Mint.WebSocket.encode(ws, {:text, msg})
          {:ok, c} = Mint.WebSocket.stream_request_body(c, ref, data)
          {c, ws}
        end)

      # Collect all responses
      received_messages = collect_messages(conn, websocket, ref, [], 10, 5000)

      # Should receive all 10 echoed messages
      assert length(received_messages) == 10

      # Verify each message is present
      for i <- 1..10 do
        expected = "Backend echo: Message #{i}"
        assert expected in received_messages
      end

      Mint.HTTP.close(conn)
    end

    @tag :websocket
    test "handles empty text frame" do
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5000)

      # Send empty text frame
      {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, ""})
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

      # Should receive empty echo
      {_conn, _websocket, received_data} = receive_ws_data(conn, websocket, ref, 2000)
      {:ok, _websocket, frames} = Mint.WebSocket.decode(websocket, received_data)

      {:text, text} =
        hd(
          Enum.filter(frames, fn
            {:text, _} -> true
            _ -> false
          end)
        )

      assert text == "Backend echo: "

      Mint.HTTP.close(conn)
    end
  end

  # Helper for WebSocket upgrade
  defp wait_for_ws_upgrade(conn, ref, timeout) do
    wait_for_ws_upgrade(conn, ref, timeout, nil, nil)
  end

  defp wait_for_ws_upgrade(conn, ref, timeout, status, headers) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case process_upgrade(responses, conn, ref, status, headers) do
              {:ok, conn, websocket} ->
                {:ok, conn, websocket}

              {:continue, conn, status, headers} ->
                wait_for_ws_upgrade(conn, ref, timeout, status, headers)
            end

          :unknown ->
            wait_for_ws_upgrade(conn, ref, timeout, status, headers)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp process_upgrade([], conn, _ref, nil, _headers), do: {:continue, conn, nil, nil}
  defp process_upgrade([], conn, _ref, _status, nil), do: {:continue, conn, nil, nil}

  defp process_upgrade([], conn, ref, status, headers) do
    # Have both status and headers, create WebSocket
    case Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} -> {:ok, conn, websocket}
      {:error, _conn, _reason} -> {:continue, conn, status, headers}
    end
  end

  defp process_upgrade([{:status, ref, status} | rest], conn, ref, _prev_status, headers) do
    process_upgrade(rest, conn, ref, status, headers)
  end

  defp process_upgrade([{:headers, ref, headers} | rest], conn, ref, status, _prev_headers) do
    process_upgrade(rest, conn, ref, status, headers)
  end

  defp process_upgrade([{:done, ref} | rest], conn, ref, status, headers) do
    process_upgrade(rest, conn, ref, status, headers)
  end

  defp process_upgrade([_response | rest], conn, ref, status, headers) do
    process_upgrade(rest, conn, ref, status, headers)
  end

  defp receive_ws_data(conn, websocket, ref, timeout) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case find_data_response(responses, ref) do
              {:ok, data} -> {conn, websocket, data}
              :not_found -> receive_ws_data(conn, websocket, ref, timeout)
            end

          :unknown ->
            receive_ws_data(conn, websocket, ref, timeout)
        end
    after
      timeout -> raise "Timeout waiting for WebSocket data"
    end
  end

  defp find_data_response([], _ref), do: :not_found

  defp find_data_response([{:data, ref, data} | _rest], ref), do: {:ok, data}

  defp find_data_response([_response | rest], ref) do
    find_data_response(rest, ref)
  end

  # Collect multiple messages
  defp collect_messages(_conn, _websocket, _ref, acc, 0, _timeout), do: Enum.reverse(acc)

  defp collect_messages(conn, websocket, ref, acc, remaining, timeout) do
    try do
      {conn, websocket, received_data} = receive_ws_data(conn, websocket, ref, timeout)
      {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, received_data)

      text_messages =
        Enum.filter(frames, fn
          {:text, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:text, text} -> text end)

      collect_messages(
        conn,
        websocket,
        ref,
        text_messages ++ acc,
        remaining - length(text_messages),
        timeout
      )
    rescue
      # If timeout, return what we have
      _ -> Enum.reverse(acc)
    end
  end
end
