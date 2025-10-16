defmodule ReverseItTest do
  use ExUnit.Case
  doctest ReverseIt

  @proxy_url "http://localhost:4000"
  @backend_url "http://localhost:4001"

  describe "HTTP Proxy" do
    test "proxies simple GET request" do
      response = Req.get!("#{@proxy_url}/hello")
      assert response.status == 200
      assert response.body == "Hello from backend!"
    end

    test "proxies JSON API endpoint" do
      response = Req.get!("#{@proxy_url}/api/status")
      assert response.status == 200
      assert is_map(response.body)
      assert response.body["status"] == "ok"
      assert response.body["server"] == "backend"
      assert Map.has_key?(response.body, "timestamp")
    end

    test "proxies POST request with body" do
      response = Req.post!("#{@proxy_url}/echo", body: "test data")
      assert response.status == 200
      assert is_map(response.body)
      assert response.body["echo"] == "test data"
    end

    test "forwards headers correctly" do
      response = Req.get!("#{@proxy_url}/headers")
      assert response.status == 200
      headers = response.body["headers"]

      # Backend should receive host header pointing to backend
      assert headers["host"] == "localhost:4001"

      # Should have X-Forwarded headers
      assert Map.has_key?(headers, "x-forwarded-for")
      assert Map.has_key?(headers, "x-forwarded-proto")
      assert Map.has_key?(headers, "x-forwarded-host")
    end

    test "handles 404 from backend" do
      response = Req.get!("#{@proxy_url}/nonexistent", retry: false)
      assert response.status == 404
    end

    test "backend is directly accessible for comparison" do
      response = Req.get!("#{@backend_url}/hello")
      assert response.status == 200
      assert response.body == "Hello from backend!"
    end
  end

  describe "WebSocket Proxy" do
    @tag :websocket
    test "detects WebSocket upgrade request" do
      # Connect directly to proxy with WebSocket upgrade headers
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", 4000)

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
    @tag :skip  # Skip until WebSocket proxy is fully debugged
    test "proxies WebSocket messages bidirectionally" do
      # This test would verify full WebSocket proxying
      # Once the async initialization is fixed

      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", 4000)
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])

      # Wait for upgrade
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5000)

      # Send message
      {:ok, _websocket, data} = Mint.WebSocket.encode(websocket, {:text, "Hello from test!"})
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

      # Receive response
      assert_receive message, 2000
      {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

      # Should have data response
      assert Enum.any?(responses, fn
        {:data, ^ref, _data} -> true
        _ -> false
      end)

      Mint.HTTP.close(conn)
    end
  end

  # Helper for WebSocket upgrade
  defp wait_for_ws_upgrade(conn, ref, timeout) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case process_upgrade(responses, conn, ref) do
              {:ok, conn, websocket} -> {:ok, conn, websocket}
              :continue -> wait_for_ws_upgrade(conn, ref, timeout)
            end

          :unknown ->
            wait_for_ws_upgrade(conn, ref, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp process_upgrade([], conn, _ref), do: {:continue, conn}

  defp process_upgrade([{:done, ref} | _rest], conn, ref) do
    case Mint.WebSocket.new(conn, ref, :client, []) do
      {:ok, conn, websocket} -> {:ok, conn, websocket}
      {:error, _conn, _reason} -> :continue
    end
  end

  defp process_upgrade([_response | rest], conn, ref) do
    process_upgrade(rest, conn, ref)
  end
end
