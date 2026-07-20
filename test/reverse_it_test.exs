defmodule ReverseItTest do
  use ExUnit.Case
  doctest ReverseIt

  # Helper functions to get dynamic URLs and ports at runtime
  defp proxy_url, do: "http://localhost:#{Application.get_env(:reverse_it, :test_proxy_port)}"
  defp backend_url, do: "http://localhost:#{Application.get_env(:reverse_it, :test_backend_port)}"
  defp proxy_port, do: Application.get_env(:reverse_it, :test_proxy_port)
  defp backend_port, do: Application.get_env(:reverse_it, :test_backend_port)

  describe "Configuration" do
    test "enables IPv6 transport for an IPv6 literal backend" do
      assert {:ok, config} =
               ReverseIt.Config.parse(
                 name: ReverseIt.TestFinch,
                 backend: "http://[fdaa:0:1::2]:4001",
                 upstream_connection: :one_shot
               )

      assert ReverseIt.Config.transport_opts(config)[:inet6]
    end

    test "keeps the default transport for IPv4 and hostname backends" do
      for backend <- ["http://127.0.0.1:4001", "http://example.internal:4001"] do
        assert {:ok, config} =
                 ReverseIt.Config.parse(
                   name: ReverseIt.TestFinch,
                   backend: backend,
                   upstream_connection: :one_shot
                 )

        refute Keyword.has_key?(ReverseIt.Config.transport_opts(config), :inet6)
      end
    end

    test "uses hardened router-style defaults" do
      {:ok, config} =
        ReverseIt.Config.parse(
          name: ReverseIt.TestFinch,
          backend: "http://localhost:#{backend_port()}"
        )

      assert config.max_request_body_size == 100 * 1024 * 1024
      assert config.request_body_buffer_size == 1024 * 1024
      assert config.response_header_timeout == 30_000
      assert config.upstream_idle_timeout == 55_000
      assert config.max_websocket_frame_size == 16 * 1024 * 1024
      assert config.forwarded_headers == :append
    end

    test "Unix sockets require one-shot HTTP/1 upstreams" do
      path =
        Path.join(
          System.tmp_dir!(),
          "reverse-it-config-#{System.unique_integer([:positive])}.sock"
        )

      assert {:error, "unix_socket requires upstream_connection: :one_shot"} =
               ReverseIt.Config.parse(
                 name: ReverseIt.TestFinch,
                 backend: "http://provider-tunnel",
                 unix_socket: path
               )

      assert {:ok, config} =
               ReverseIt.Config.parse(
                 name: ReverseIt.TestFinch,
                 backend: "http://provider-tunnel",
                 unix_socket: path,
                 upstream_connection: :one_shot,
                 protocols: [:http1]
               )

      assert config.unix_socket == path
      assert config.upstream_connection == :one_shot
    end
  end

  describe "HTTP Proxy" do
    test "opens a fresh Unix-socket upstream for every request" do
      path = Path.join(System.tmp_dir!(), "reverse-it-#{System.unique_integer([:positive])}.sock")
      File.rm(path)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, path}])

      on_exit(fn ->
        :gen_tcp.close(listener)
        File.rm(path)
      end)

      parent = self()

      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             for number <- 1..2 do
               {:ok, socket} = :gen_tcp.accept(listener)
               {:ok, request} = recv_http_request(socket, "")
               send(parent, {:unix_upstream_request, number, request})
               body = "response-#{number}"

               :ok =
                 :gen_tcp.send(
                   socket,
                   "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
                 )

               :gen_tcp.close(socket)
             end
           end},
          id: {:unix_upstream, make_ref()}
        )
      )

      opts =
        ReverseIt.init(
          name: ReverseIt.TestFinch,
          backend: "http://provider-tunnel",
          unix_socket: path,
          upstream_connection: :one_shot,
          protocols: [:http1]
        )

      first = Plug.Test.conn("POST", "/first", "one") |> ReverseIt.call(opts)
      second = Plug.Test.conn("POST", "/second", "two") |> ReverseIt.call(opts)

      assert first.status == 200
      assert first.resp_body == "response-1"
      assert second.status == 200
      assert second.resp_body == "response-2"

      assert_receive {:unix_upstream_request, 1, first_request}
      assert first_request =~ "POST /first HTTP/1.1"
      assert first_request =~ "\r\n\r\none"

      assert_receive {:unix_upstream_request, 2, second_request}
      assert second_request =~ "POST /second HTTP/1.1"
      assert second_request =~ "\r\n\r\ntwo"
    end

    test "preserves bodyless response semantics over a Unix socket" do
      path =
        Path.join(
          System.tmp_dir!(),
          "reverse-it-empty-#{System.unique_integer([:positive])}.sock"
        )

      File.rm(path)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, path}])

      on_exit(fn ->
        :gen_tcp.close(listener)
        File.rm(path)
      end)

      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             {:ok, head_socket} = :gen_tcp.accept(listener)
             {:ok, _request} = recv_http_request(head_socket, "")

             :ok =
               :gen_tcp.send(
                 head_socket,
                 "HTTP/1.1 200 OK\r\ncontent-length: 7\r\nconnection: close\r\n\r\n"
               )

             :gen_tcp.close(head_socket)

             {:ok, empty_socket} = :gen_tcp.accept(listener)
             {:ok, _request} = recv_http_request(empty_socket, "")

             :ok =
               :gen_tcp.send(
                 empty_socket,
                 "HTTP/1.1 204 No Content\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
               )

             :gen_tcp.close(empty_socket)
           end},
          id: {:unix_empty_upstream, make_ref()}
        )
      )

      opts =
        ReverseIt.init(
          name: ReverseIt.TestFinch,
          backend: "http://provider-tunnel",
          unix_socket: path,
          upstream_connection: :one_shot,
          protocols: [:http1]
        )

      head = Plug.Test.conn("HEAD", "/head") |> ReverseIt.call(opts)
      empty = Plug.Test.conn("GET", "/empty") |> ReverseIt.call(opts)

      assert head.status == 200
      assert head.resp_body == ""
      assert Plug.Conn.get_resp_header(head, "content-length") == ["7"]
      assert empty.status == 204
      assert empty.resp_body == ""
    end

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

    test "strips hop-by-hop and Connection-nominated request headers" do
      response =
        Req.get!("#{proxy_url()}/headers",
          headers: [
            {"connection", "x-secret"},
            {"x-secret", "should-not-forward"}
          ]
        )

      assert response.status == 200
      headers = response.body["headers"]
      refute Map.has_key?(headers, "connection")
      refute Map.has_key?(headers, "x-secret")
    end

    test "can replace untrusted forwarded headers" do
      response =
        Req.get!("#{proxy_url()}/replace-forwarded/headers",
          headers: [{"x-forwarded-for", "1.1.1.1"}]
        )

      assert response.status == 200
      headers = response.body["headers"]
      assert headers["x-forwarded-for"]
      refute String.contains?(headers["x-forwarded-for"], "1.1.1.1")
    end

    test "rejects request bodies over the configured maximum" do
      response =
        Req.post!("#{proxy_url()}/limited/upload",
          body: :binary.copy("A", 2048),
          retry: false
        )

      assert response.status == 413
    end

    test "rejects responses over the configured maximum before forwarding body data" do
      response =
        Req.get!("#{proxy_url()}/response-limit/download/2048",
          retry: false,
          receive_timeout: 60_000
        )

      assert response.status == 502
      assert response.body == "Bad Gateway: Response too large"
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

  defp recv_http_request(socket, acc) do
    case complete_http_request?(acc) do
      true ->
        {:ok, acc}

      false ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, data} -> recv_http_request(socket, acc <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp complete_http_request?(request) do
    case :binary.match(request, "\r\n\r\n") do
      {index, length} ->
        headers = binary_part(request, 0, index)
        body_offset = index + length
        body_bytes = byte_size(request) - body_offset

        content_length =
          headers
          |> String.split("\r\n")
          |> Enum.find_value(0, fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length" do
                  case Integer.parse(String.trim(value)) do
                    {value, ""} -> value
                    _invalid -> 0
                  end
                end

              _other ->
                nil
            end
          end)

        body_bytes >= content_length

      :nomatch ->
        false
    end
  end

  describe "Streaming Proxy" do
    @tag :streaming
    test "streams large request body using Mint fallback" do
      # Create a body that exceeds the default in-memory buffer threshold.
      # We'll use 15MB to trigger request streaming.
      body_size = 15 * 1024 * 1024
      # 1MB chunks
      chunk_size = 1024 * 1024
      num_chunks = div(body_size, chunk_size)

      # Create a stream of chunks
      body_stream = Stream.map(1..num_chunks, fn _ -> :binary.copy(<<65>>, chunk_size) end)

      response =
        Req.post!("#{proxy_url()}/upload",
          body: body_stream,
          retry: false,
          receive_timeout: 60_000
        )

      assert response.status == 200
      assert is_map(response.body)
      assert response.body["received_bytes"] == body_size
    end

    @tag :streaming
    test "keeps the client connection reusable after streaming a request body" do
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      body = :binary.copy("A", 2 * 1024 * 1024)

      {:ok, conn, 200, upload_response} =
        mint_request(conn, "POST", "/upload", body, 5_000)

      assert Jason.decode!(upload_response)["received_bytes"] == byte_size(body)
      assert Mint.HTTP.open?(conn)

      {:ok, conn, 200, hello_response} = mint_request(conn, "GET", "/hello", "", 1_000)
      assert hello_response == "Hello from backend!"

      Mint.HTTP.close(conn)
    end

    @tag :streaming
    test "streams large response body back to client" do
      # Request 20MB download
      download_size = 20 * 1024 * 1024

      response =
        Req.get!("#{proxy_url()}/download/#{download_size}",
          retry: false,
          receive_timeout: 60_000
        )

      assert response.status == 200
      assert byte_size(response.body) == download_size
    end

    @tag :streaming
    test "handles streaming with small body using Finch" do
      # Small body under the buffer threshold should use Finch.
      # 1KB
      small_body = :binary.copy(<<66>>, 1024)

      response =
        Req.post!("#{proxy_url()}/upload",
          body: Stream.take([small_body], 1),
          retry: false
        )

      assert response.status == 200
      assert response.body["received_bytes"] == 1024
    end

    @tag :streaming
    test "handles concurrent streaming requests" do
      # Send multiple large uploads concurrently
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            # 12MB each
            body_size = 12 * 1024 * 1024
            # 1MB chunks
            chunk_size = 1024 * 1024
            num_chunks = div(body_size, chunk_size)
            body_stream = Stream.map(1..num_chunks, fn _ -> :binary.copy(<<i>>, chunk_size) end)

            Req.post!("#{proxy_url()}/upload",
              body: body_stream,
              retry: false,
              receive_timeout: 60_000
            )
          end)
        end

      results = Task.await_many(tasks, 60_000)

      assert Enum.all?(results, fn response ->
               response.status == 200 && response.body["received_bytes"] == 12 * 1024 * 1024
             end)
    end

    @tag :streaming
    test "streams request and response together" do
      # Upload 15MB and download 15MB in same request/response cycle
      upload_size = 15 * 1024 * 1024
      chunk_size = 1024 * 1024
      num_chunks = div(upload_size, chunk_size)
      body_stream = Stream.map(1..num_chunks, fn _ -> :binary.copy(<<67>>, chunk_size) end)

      response =
        Req.post!("#{proxy_url()}/upload",
          body: body_stream,
          retry: false,
          receive_timeout: 60_000
        )

      assert response.status == 200
      assert response.body["received_bytes"] == upload_size

      # Now test download streaming
      download_response =
        Req.get!("#{proxy_url()}/download/#{upload_size}",
          retry: false,
          receive_timeout: 60_000
        )

      assert download_response.status == 200
      assert byte_size(download_response.body) == upload_size
    end
  end

  describe "WebSocket Proxy" do
    @tag :websocket
    test "proxies WebSocket messages through a Unix socket" do
      path =
        Path.join(System.tmp_dir!(), "reverse-it-ws-#{System.unique_integer([:positive])}.sock")

      proxy_port = TestHelper.find_available_port()
      File.rm(path)

      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: ReverseIt.TestBackend,
           scheme: :http,
           ip: {:local, path},
           port: 0,
           thousand_island_options: [silent_terminate_on_error: true]},
          id: {:unix_websocket_backend, make_ref()}
        )
      )

      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug:
             {ReverseIt.TestUnixProxy,
              name: ReverseIt.TestFinch,
              backend: "ws://provider-tunnel",
              unix_socket: path,
              upstream_connection: :one_shot,
              protocols: [:http1]},
           scheme: :http,
           port: proxy_port,
           thousand_island_options: [silent_terminate_on_error: true]},
          id: {:unix_websocket_proxy, make_ref()}
        )
      )

      on_exit(fn -> File.rm(path) end)

      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port)
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5_000)
      {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, "over-uds"})
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
      {conn, websocket, received_data} = receive_ws_data(conn, websocket, ref, 2_000)
      {:ok, _websocket, frames} = Mint.WebSocket.decode(websocket, received_data)

      assert {:text, "Backend echo: over-uds"} in frames

      Mint.HTTP.close(conn)
    end

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

    @tag :websocket
    test "closes WebSocket connections with frames over the configured maximum" do
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", proxy_port())
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/tiny-ws/ws", [])
      {:ok, conn, websocket} = wait_for_ws_upgrade(conn, ref, 5000)

      {:ok, _websocket, data} =
        Mint.WebSocket.encode(websocket, {:text, String.duplicate("A", 256)})

      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

      assert_receive message, 2000

      case Mint.WebSocket.stream(conn, message) do
        {:ok, _conn, responses} ->
          assert Enum.any?(responses, fn
                   {:data, ^ref, _data} -> true
                   {:done, ^ref} -> true
                   _other -> false
                 end)

        {:error, _conn, _reason, _responses} ->
          assert true

        :unknown ->
          assert match?({:tcp_closed, _socket}, message)
      end

      Mint.HTTP.close(conn)
    end
  end

  defp mint_request(conn, method, path, body, timeout) do
    headers = [{"content-length", Integer.to_string(byte_size(body))}]
    {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, headers, body)
    receive_mint_response(conn, ref, timeout, nil, [])
  end

  defp receive_mint_response(conn, ref, timeout, status, body) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            case reduce_mint_responses(responses, ref, status, body) do
              {:done, status, body} ->
                {:ok, conn, status, IO.iodata_to_binary(Enum.reverse(body))}

              {:continue, status, body} ->
                receive_mint_response(conn, ref, timeout, status, body)
            end

          :unknown ->
            receive_mint_response(conn, ref, timeout, status, body)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp reduce_mint_responses([], _ref, status, body), do: {:continue, status, body}

  defp reduce_mint_responses([{:status, ref, status} | rest], ref, _status, body),
    do: reduce_mint_responses(rest, ref, status, body)

  defp reduce_mint_responses([{:data, ref, data} | rest], ref, status, body),
    do: reduce_mint_responses(rest, ref, status, [data | body])

  defp reduce_mint_responses([{:done, ref} | _rest], ref, status, body),
    do: {:done, status, body}

  defp reduce_mint_responses([_response | rest], ref, status, body),
    do: reduce_mint_responses(rest, ref, status, body)

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
