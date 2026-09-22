defmodule ReverseIt.ResponseHandlerTest do
  use ExUnit.Case, async: true

  alias ReverseIt.TestResponseHandler, as: Handler

  for mode <- [:pooled, :one_shot] do
    @mode mode

    test "#{mode}: buffers an error without committing or halting the connection" do
      {port, _} = backend("HTTP/1.1 429 Slow Down\r\nContent-Length: 5\r\n\r\nretry")
      config = config(@mode, port, {:buffer, 100})

      assert {:buffered, %{status: 429, body: "retry", headers: headers}, conn, state} =
               ReverseIt.request(Plug.Test.conn(:get, "/"), config)

      assert {"content-length", "5"} in headers
      refute conn.state in [:sent, :chunked]
      refute conn.halted
      assert state.mode == {:buffer, 100}
      assert_receive {:terminated, :buffered, ^state}
      refute_receive {:data, _}
      assert Plug.Conn.send_resp(conn, 200, "replacement").resp_body == "replacement"
    end

    test "#{mode}: the Plug entry point sends buffered responses" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
      conn = ReverseIt.call(Plug.Test.conn(:get, "/"), config(@mode, port, {:buffer, 100}))
      assert conn.status == 200
      assert conn.resp_body == "hello"
      assert conn.halted
    end

    test "#{mode}: forwards an already-consumed body with correct framing" do
      port = Application.fetch_env!(:reverse_it, :test_backend_port)
      payload = <<0, 1, 2, 127>> <> "exact bytes"
      conn = Plug.Test.conn(:post, "/echo", "previous body")
      {:ok, _, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.put_req_header(conn, "content-length", "9999")

      config =
        config(@mode, port, {:buffer, 1024}, request_body: payload, max_request_body_size: 100)

      assert {:buffered, response, _conn, _} = ReverseIt.request(conn, config)
      assert Jason.decode!(response.body)["echo"] == payload
    end

    test "#{mode}: rejects oversized supplied bytes before connecting" do
      config = config(@mode, 1, {:buffer, 10}, request_body: "12345", max_request_body_size: 4)

      assert {:error, :request_body_too_large, conn, state} =
               ReverseIt.request(Plug.Test.conn(:post, "/"), config)

      assert conn.state == :unset
      assert_receive {:terminated, {:error, :request_body_too_large}, ^state}
    end

    test "#{mode}: supplies an empty body without reading the consumed request" do
      port = Application.fetch_env!(:reverse_it, :test_backend_port)

      assert {:buffered, response, _, _} =
               ReverseIt.request(
                 Plug.Test.conn(:post, "/echo", "ignore me"),
                 config(@mode, port, {:buffer, 100}, request_body: "")
               )

      assert Jason.decode!(response.body)["echo"] == ""
    end

    test "#{mode}: filters headers and removes stale length when transforming bytes" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

      assert {:ok, conn, state} =
               ReverseIt.request(Plug.Test.conn(:get, "/"), config(@mode, port, :suffix))

      assert conn.resp_body == "hello!"
      assert Plug.Conn.get_resp_header(conn, "content-length") == []
      assert Plug.Conn.get_resp_header(conn, "x-processed") == ["yes"]
      assert state.bytes == 5
      assert_receive {:terminated, :ok, ^state}
    end

    test "#{mode}: rejects a response at headers without committing it" do
      {port, _} =
        backend("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 99\r\n\r\n")

      assert {:error, :unsupported_encoding, conn, state} =
               ReverseIt.request(Plug.Test.conn(:get, "/"), config(@mode, port, :reject))

      assert conn.state == :unset
      assert_receive {:terminated, {:error, :unsupported_encoding}, ^state}
      refute_receive {:data, _}
    end

    test "#{mode}: bounds buffers with and without Content-Length" do
      for response <- [
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
          ] do
        {port, _} = backend(response)

        assert {:error, :response_buffer_too_large, conn, _} =
                 ReverseIt.request(Plug.Test.conn(:get, "/"), config(@mode, port, {:buffer, 4}))

        assert conn.state == :unset
      end
    end

    test "#{mode}: configured response limit bounds buffered and transformed output" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

      assert {:error, :response_body_too_large, _, _} =
               ReverseIt.request(
                 Plug.Test.conn(:get, "/"),
                 config(@mode, port, {:buffer, 100}, max_response_body_size: 4)
               )

      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

      assert {:error, :response_body_too_large, conn, _} =
               ReverseIt.request(
                 Plug.Test.conn(:get, "/"),
                 config(@mode, port, :expand, max_response_body_size: 8)
               )

      assert conn.state == :unset
    end

    test "#{mode}: retains framing state across transport chunks" do
      {port, upstream} =
        backend(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nsec\r\n",
          "4\r\nret\n\r\n0\r\n\r\n"
        )

      config = config(@mode, port, :frames)
      task = Task.async(fn -> ReverseIt.request(Plug.Test.conn(:get, "/"), config) end)
      assert_receive {:data, "sec"}, 2000
      send(upstream, :finish)
      assert {:ok, conn, %{pending: ""}} = Task.await(task)
      assert conn.resp_body == "REDACTED\n"
    end

    test "#{mode}: reports incomplete transformed frames and aborts committed responses" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nsec")

      assert catch_exit(
               ReverseIt.request(Plug.Test.conn(:get, "/"), config(@mode, port, :frames))
             ) ==
               {:upstream_stream_failed, :incomplete_frame}

      assert_receive {:terminated, {:error, :incomplete_frame}, %{pending: "sec"}}
      refute_receive {:terminated, _, _}
    end

    test "#{mode}: returns truncation before commitment and reports it after commitment" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")

      assert {:error, _, conn, _} =
               ReverseIt.request(Plug.Test.conn(:get, "/"), config(@mode, port, {:buffer, 100}))

      assert conn.state == :unset
      assert_receive {:terminated, {:error, _}, _}

      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")

      assert {:upstream_stream_failed, _} =
               catch_exit(
                 ReverseIt.request(Plug.Test.conn(:get, "/"), config(@mode, port, :passthrough))
               )

      assert_receive {:terminated, {:error, _}, _}
    end

    test "#{mode}: streams to a real client before the upstream finishes" do
      {port, upstream} =
        backend(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\none\n\r\n",
          "4\r\ntwo\n\r\n0\r\n\r\n"
        )

      proxy = proxy(config(@mode, port, :frames))
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, proxy, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(socket) end)

      :ok =
        :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

      first = recv_until(socket, "one\n")
      assert first =~ "200 OK"
      send(upstream, :finish)
      assert recv_until(socket, "two\n") =~ "two\n"
      assert_receive {:terminated, :ok, _}, 2000
    end

    test "#{mode}: buffered HEAD responses do not consume representation bytes" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 9999\r\n\r\n")

      assert {:buffered, %{body: "", headers: headers}, _, _} =
               ReverseIt.request(
                 Plug.Test.conn(:head, "/"),
                 config(@mode, port, {:buffer, 0}, max_response_body_size: 0)
               )

      assert {"content-length", "9999"} in headers
    end

    test "#{mode}: caller can replay a validated POST after an unsent error response" do
      {port, _} = backend("HTTP/1.1 429 Retry\r\nContent-Length: 0\r\n\r\n")
      conn = Plug.Test.conn(:post, "/echo", "validated body")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      config = config(@mode, port, {:buffer, 1024}, request_body: body)
      assert {:buffered, %{status: 429}, conn, _} = ReverseIt.request(conn, config)
      port = Application.fetch_env!(:reverse_it, :test_backend_port)
      assert {:buffered, response, _, _} = ReverseIt.request(conn, %{config | port: port})
      assert Jason.decode!(response.body)["echo"] == body
    end

    test "#{mode}: callbacks also work with streamed request bodies" do
      port = Application.fetch_env!(:reverse_it, :test_backend_port)
      body = String.duplicate("large upload", 100)

      config =
        config(@mode, port, {:buffer, 4096},
          request_body_buffer_size: 8,
          request_body_chunk_size: 4
        )

      assert {:buffered, response, _, _} =
               ReverseIt.request(Plug.Test.conn(:post, "/echo", body), config)

      assert Jason.decode!(response.body)["echo"] == body
    end

    test "#{mode}: cancellation closes upstream and reports the final observer state" do
      owner = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, _} = :gen_tcp.recv(socket, 0, 2000)
           :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nfirst")
           send(owner, {:upstream_closed, :gen_tcp.recv(socket, 0, 2000)})
           :gen_tcp.close(socket)
         end}
      )

      conn = Plug.Test.conn(:get, "/")
      {_, adapter_state} = conn.adapter
      conn = %{conn | adapter: {ReverseIt.DisconnectedAdapter, adapter_state}}

      assert catch_exit(ReverseIt.request(conn, config(@mode, port, :passthrough))) ==
               {:upstream_stream_failed, {:downstream, :closed}}

      assert_receive {:terminated, {:error, {:downstream, :closed}}, %{bytes: 5}}
      assert_receive {:upstream_closed, {:error, :closed}}, 2000
      refute_receive {:terminated, _, _}
    end

    test "#{mode}: callback exceptions close the upstream connection" do
      owner = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, _} = :gen_tcp.recv(socket, 0, 2000)
           :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nfirst")
           send(owner, {:upstream_closed, :gen_tcp.recv(socket, 0, 2000)})
           :gen_tcp.close(socket)
         end}
      )

      assert_raise RuntimeError, "handler bug", fn ->
        ReverseIt.request(Plug.Test.conn(:get, "/"), config(@mode, port, :raise))
      end

      assert_receive {:upstream_closed, {:error, :closed}}, 2000
    end
  end

  test "rejects invalid handlers and request body types" do
    assert_raise ArgumentError, ~r/response_handler/, fn ->
      ReverseIt.init(name: Unused, backend: "http://localhost", response_handler: {String, nil})
    end

    assert_raise ArgumentError, ~r/request_body/, fn ->
      ReverseIt.init(name: Unused, backend: "http://localhost", request_body: ["iodata"])
    end
  end

  test "request API rejects WebSocket upgrades before contacting upstream" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("connection", "upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")

    config = ReverseIt.init(name: Unused, backend: "http://localhost:1")
    assert {:error, :websocket_not_supported, ^conn, nil} = ReverseIt.request(conn, config)
  end

  test "direct header timeout preserves the Plug's 504 and exposes an unsent API error" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         for _ <- 1..2 do
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, _} = :gen_tcp.recv(socket, 0, 2000)
           {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
           :gen_tcp.close(socket)
         end
       end}
    )

    config = config(:one_shot, port, {:buffer, 100}, response_header_timeout: 20)

    assert {:error, {:response_headers, %Mint.TransportError{reason: :timeout}}, conn, _} =
             ReverseIt.request(Plug.Test.conn(:get, "/"), config)

    assert conn.state == :unset
    conn = ReverseIt.call(conn, %{config | response_handler: nil})
    assert conn.status == 504
  end

  defp config(connection_mode, port, handler_mode, opts \\ []) do
    ReverseIt.init(
      Keyword.merge(
        [
          name: ReverseIt.TestFinch,
          backend: "http://127.0.0.1:#{port}",
          upstream_connection: connection_mode,
          response_handler: {Handler, %{owner: self(), mode: handler_mode}}
        ],
        opts
      )
    )
  end

  defp backend(response, remaining \\ nil) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    task =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Task, :start_link,
           [
             fn ->
               {:ok, socket} = :gen_tcp.accept(listener)
               {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
               :ok = :gen_tcp.send(socket, response)

               if remaining do
                 receive do
                   :finish -> :ok = :gen_tcp.send(socket, remaining)
                 after
                   5000 -> raise "proxy did not stream before upstream completion"
                 end
               end

               :gen_tcp.close(socket)
             end
           ]}
      })

    {port, task}
  end

  defp proxy(config) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {ReverseIt.TestHandledProxy, config},
         port: 0,
         ip: {127, 0, 0, 1},
         thousand_island_options: [silent_terminate_on_error: true]}
      )

    TestHelper.listener_port(pid)
  end

  defp recv_until(socket, marker, data \\ "") do
    if String.contains?(data, marker) do
      data
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 2000)
      recv_until(socket, marker, data <> chunk)
    end
  end
end
