defmodule ReverseIt.ResponseHandlerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  @moduletag :capture_log

  alias ReverseIt.TestResponseHandler, as: Handler

  for mode <- [:pooled, :one_shot] do
    @mode mode

    test "#{mode}: buffers an error without committing or halting the connection" do
      {port, _} = backend("HTTP/1.1 429 Slow Down\r\nContent-Length: 5\r\n\r\nretry")
      config = config(@mode, port, {:buffer, 100})

      assert {:buffered, %{status: 429, body: "retry", headers: headers}, conn, state} =
               request(Plug.Test.conn(:get, "/"), config)

      assert {"content-length", "5"} in headers
      refute conn.state in [:sent, :chunked]
      refute conn.halted
      assert state.mode == {:buffer, 100}
      assert_receive {:terminated, :buffered, ^state}
      refute_receive {:data, _}
      assert Plug.Conn.send_resp(conn, 200, "replacement").resp_body == "replacement"
    end

    test "#{mode}: buffered responses preserve repeated headers and replace defaults" do
      {port, _} =
        backend(
          "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n" <>
            "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\nCache-Control: public\r\n\r\nhello"
        )

      assert {:buffered, response, conn, _} =
               request(Plug.Test.conn(:get, "/"), config(@mode, port, {:buffer, 100}))

      assert Plug.Conn.get_resp_header(conn, "cache-control") == [
               "max-age=0, private, must-revalidate"
             ]

      owner = self()

      conn =
        conn
        |> Plug.Conn.register_before_send(fn conn ->
          send(owner, :before_send)
          Plug.Conn.put_resp_header(conn, "x-wrapper", "yes")
        end)
        |> ReverseIt.send_buffered(response)

      assert conn.status == 200
      assert conn.resp_body == "hello"
      assert conn.state == :sent
      refute conn.halted
      assert Plug.Conn.get_resp_header(conn, "set-cookie") == ["a=1", "b=2"]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["public"]
      assert Plug.Conn.get_resp_header(conn, "x-wrapper") == ["yes"]
      assert_receive :before_send
      refute_receive :before_send
    end

    test "#{mode}: a wrapper sends every buffered cookie to a real client" do
      {port, _} =
        backend(
          "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n" <>
            "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\nCache-Control: public\r\n\r\nhello"
        )

      proxy = proxy(config(@mode, port, {:buffer, 100}))
      response = Req.get!("http://127.0.0.1:#{proxy}")
      assert response.status == 200
      assert response.body == "hello"
      assert response.headers["set-cookie"] == ["a=1", "b=2"]
      assert response.headers["cache-control"] == ["public"]
    end

    test "#{mode}: forwards an already-consumed body with correct framing" do
      port = Application.fetch_env!(:reverse_it, :test_backend_port)
      payload = <<0, 1, 2, 127>> <> "exact bytes"
      conn = Plug.Test.conn(:post, "/echo", "previous body")
      {:ok, _, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.put_req_header(conn, "content-length", "9999")

      config =
        config(@mode, port, {:buffer, 1024}, request_body: payload, max_request_body_size: 100)

      assert {:buffered, response, _conn, _} = request(conn, config)
      assert Jason.decode!(response.body)["echo"] == payload
    end

    test "#{mode}: rejects oversized supplied bytes before connecting" do
      config = config(@mode, 1, {:buffer, 10}, request_body: "12345", max_request_body_size: 4)

      assert {:error, :request_body_too_large, conn, state} =
               request(Plug.Test.conn(:post, "/"), config)

      assert conn.state == :unset
      assert_receive {:terminated, {:error, :request_body_too_large}, ^state}
    end

    test "#{mode}: supplies an empty body without reading the consumed request" do
      port = Application.fetch_env!(:reverse_it, :test_backend_port)

      assert {:buffered, response, _, _} =
               request(
                 Plug.Test.conn(:post, "/echo", "ignore me"),
                 config(@mode, port, {:buffer, 100}, request_body: "")
               )

      assert Jason.decode!(response.body)["echo"] == ""
    end

    test "#{mode}: filters headers and removes stale length when transforming bytes" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

      assert {:ok, conn, state} =
               request(Plug.Test.conn(:get, "/"), config(@mode, port, :suffix))

      assert conn.resp_body == "hello!"
      assert Plug.Conn.get_resp_header(conn, "content-length") == []
      assert Plug.Conn.get_resp_header(conn, "x-processed") == ["yes"]
      assert state.bytes == 5
      assert_receive {:terminated, :ok, ^state}
    end

    test "#{mode}: rejects a response at headers without committing it" do
      {port, _} =
        backend("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 99\r\n\r\n")

      assert capture_log(fn ->
               assert {:error, :unsupported_encoding, conn, state} =
                        request(Plug.Test.conn(:get, "/"), config(@mode, port, :reject))

               assert conn.state == :unset
               assert_receive {:terminated, {:error, :unsupported_encoding}, ^state}
             end) == ""

      refute_receive {:data, _}
    end

    test "#{mode}: bounds buffers with and without Content-Length" do
      for response <- [
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
          ] do
        {port, _} = backend(response)

        assert {:error, :response_buffer_too_large, conn, _} =
                 request(Plug.Test.conn(:get, "/"), config(@mode, port, {:buffer, 4}))

        assert conn.state == :unset
      end
    end

    test "#{mode}: configured response limit bounds buffered and transformed output" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

      assert {:error, :response_body_too_large, _, _} =
               request(
                 Plug.Test.conn(:get, "/"),
                 config(@mode, port, {:buffer, 100}, max_response_body_size: 4)
               )

      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

      assert {:error, :response_body_too_large, conn, _} =
               request(
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
      task = Task.async(fn -> request(Plug.Test.conn(:get, "/"), config) end)
      assert_receive {:data, "sec"}, 2000
      send(upstream, :finish)
      assert {:ok, conn, %{pending: ""}} = Task.await(task)
      assert conn.resp_body == "REDACTED\n"
    end

    test "#{mode}: incomplete frames fail before commitment if no bytes were emitted" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nsec")

      assert {:error, :incomplete_frame, conn, _} =
               request(Plug.Test.conn(:get, "/"), config(@mode, port, :frames))

      assert conn.state == :unset
      assert_receive {:terminated, {:error, :incomplete_frame}, %{pending: "sec"}}
      refute_receive {:terminated, _, _}
    end

    test "#{mode}: incomplete frames abort after emitting a complete frame" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nok\nsec")

      assert catch_exit(request(Plug.Test.conn(:get, "/"), config(@mode, port, :frames))) ==
               {:upstream_stream_failed, :incomplete_frame}

      assert_receive {:terminated, {:error, :incomplete_frame}, %{pending: "sec"}}
      refute_receive {:terminated, _, _}
    end

    test "#{mode}: returns truncation before commitment and reports it after commitment" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")

      assert {:error, _, conn, _} =
               request(Plug.Test.conn(:get, "/"), config(@mode, port, {:buffer, 100}))

      assert conn.state == :unset
      assert_receive {:terminated, {:error, _}, _}

      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")

      assert {:upstream_stream_failed, _} =
               catch_exit(request(Plug.Test.conn(:get, "/"), config(@mode, port, :passthrough)))

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
               request(
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
      assert {:buffered, %{status: 429}, conn, _} = request(conn, config)
      port = Application.fetch_env!(:reverse_it, :test_backend_port)

      assert {:buffered, response, _, _} =
               request(conn, {%{elem(config, 0) | port: port}, elem(config, 1)})

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
               request(Plug.Test.conn(:post, "/echo", body), config)

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

      assert capture_log(fn ->
               assert catch_exit(request(conn, config(@mode, port, :passthrough))) ==
                        {:upstream_stream_failed, {:downstream, :closed}}
             end) == ""

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
        request(Plug.Test.conn(:get, "/"), config(@mode, port, :raise))
      end

      assert_receive {:upstream_closed, {:error, :closed}}, 2000
    end

    test "#{mode}: trailers never repeat the header callback or change response mode" do
      for handler_mode <- [:passthrough, {:buffer, 100}] do
        {port, _} =
          backend(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-Final\r\n\r\n" <>
              "5\r\nhello\r\n0\r\nX-Final: yes\r\n\r\n"
          )

        result = request(Plug.Test.conn(:get, "/"), config(@mode, port, handler_mode))

        case result do
          {:ok, conn, _} ->
            assert conn.resp_body == "hello"

          {:buffered, response, conn, _} ->
            assert response.body == "hello"
            assert conn.state == :unset
        end

        assert_receive {:headers, 200, headers}
        refute List.keymember?(headers, "x-final", 0)
        refute_receive {:headers, _, _}
      end
    end

    for limit <- [:infinity, 100] do
      @limit limit

      test "#{mode}: immediate headers reach a quiet stream's client with limit #{limit}" do
        {port, upstream} =
          backend(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" <>
              "Transfer-Encoding: chunked\r\n\r\n",
            "5\r\nhello\r\n0\r\n\r\n"
          )

        proxy =
          proxy(
            config(@mode, port, :passthrough, commit: :headers, max_response_body_size: @limit)
          )

        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, proxy, [:binary, active: false])
        on_exit(fn -> :gen_tcp.close(socket) end)

        :ok =
          :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

        headers = recv_until(socket, "\r\n\r\n")
        assert headers =~ "200 OK"
        assert headers =~ "content-type: text/event-stream"
        refute headers =~ "hello"
        refute_receive {:data, _}
        refute_receive {:terminated, _, _}
        send(upstream, :finish)
        assert recv_until(socket, "hello") =~ "hello"
        assert_receive {:terminated, :ok, _}, 2000
      end

      test "#{mode}: immediate headers make first-chunk rejection abort with limit #{limit}" do
        {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
        opts = config(@mode, port, :reject_data, commit: :headers, max_response_body_size: @limit)

        log =
          capture_log(fn ->
            assert catch_exit(request(Plug.Test.conn(:get, "/"), opts)) ==
                     {:upstream_stream_failed, :bad_data}
          end)

        assert length(Regex.scan(~r/Failed to proxy HTTP response/, log)) == 1
        assert log =~ "after commitment"
        assert_receive {:terminated, {:error, :bad_data}, %{bytes: 5}}
        refute_receive {:terminated, _, _}
      end
    end

    test "#{mode}: immediate bodyless responses send once and retain only HEAD length" do
      for {method, status} <- [{:head, 200}, {:get, 204}, {:get, 304}] do
        {port, _} = backend("HTTP/1.1 #{status} Empty\r\nContent-Length: 100\r\n\r\n")
        owner = self()

        conn =
          Plug.Test.conn(method, "/")
          |> Plug.Conn.register_before_send(fn conn ->
            send(owner, :before_send)
            conn
          end)

        assert {:ok, conn, _} =
                 request(
                   conn,
                   config(@mode, port, :passthrough, commit: :headers, max_response_body_size: 0)
                 )

        assert conn.state == :sent
        assert conn.status == status
        assert conn.resp_body == ""
        expected_length = if method == :head, do: ["100"], else: []
        assert Plug.Conn.get_resp_header(conn, "content-length") == expected_length
        assert_receive :before_send
        refute_receive :before_send
        assert_receive {:terminated, :ok, _}
        refute_receive {:data, _}
      end
    end

    test "#{mode}: first-chunk rejection stays unsent for every deferred option form" do
      for commit <- [nil, :output, []], limit <- [:infinity, 100] do
        {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

        assert {:error, :bad_data, conn, %{bytes: 5}} =
                 request(
                   Plug.Test.conn(:get, "/"),
                   config(@mode, port, :reject_data,
                     commit: commit,
                     max_response_body_size: limit
                   )
                 )

        assert conn.state == :unset
        assert_receive {:terminated, {:error, :bad_data}, _}
      end
    end

    test "#{mode}: explicit default commitment options stream the complete response" do
      for commit <- [:output, []] do
        {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

        assert {:ok, conn, state} =
                 request(Plug.Test.conn(:get, "/"), config(@mode, port, :suffix, commit: commit))

        assert conn.status == 200
        assert conn.resp_body == "hello!"
        assert state.bytes == 5
        assert_receive {:terminated, :ok, ^state}
      end
    end

    test "#{mode}: invalid callback headers fail before deferred or immediate commitment" do
      for commit <- [:output, :headers] do
        {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

        assert {:error, :invalid_response_header, conn, _} =
                 request(
                   Plug.Test.conn(:get, "/"),
                   config(@mode, port, :bad_headers, commit: commit)
                 )

        assert conn.state == :unset
        assert_receive {:terminated, {:error, :invalid_response_header}, _}
        refute_receive {:data, _}
      end
    end

    test "#{mode}: buffered bodyless statuses discard representation length" do
      for status <- [204, 304] do
        {port, _} = backend("HTTP/1.1 #{status} Empty\r\nContent-Length: 100\r\n\r\n")

        conn =
          ReverseIt.TestHandledProxy.call(
            Plug.Test.conn(:get, "/"),
            config(@mode, port, {:buffer, 0}, max_response_body_size: 0)
          )

        assert conn.status == status
        assert conn.resp_body == ""
        assert Plug.Conn.get_resp_header(conn, "content-length") == []
      end
    end

    test "#{mode}: finite limits permit streaming and abort overflow after emitted bytes" do
      {port, upstream} =
        backend(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\none\n\r\n",
          "4\r\ntwo\n\r\n0\r\n\r\n"
        )

      proxy = proxy(config(@mode, port, :frames, max_response_body_size: 8))
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, proxy, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(socket) end)

      :ok =
        :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

      assert recv_until(socket, "one\n") =~ "200 OK"
      send(upstream, :finish)
      assert recv_until(socket, "two\n") =~ "two\n"
      assert_receive {:terminated, :ok, _}, 2000

      {port, upstream} =
        backend(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n",
          "5\r\nworld\r\n0\r\n\r\n"
        )

      opts = config(@mode, port, :passthrough, max_response_body_size: 8)

      task =
        Task.async(fn ->
          catch_exit(request(Plug.Test.conn(:get, "/"), opts))
        end)

      assert_receive {:data, "hello"}, 2000
      send(upstream, :finish)
      assert Task.await(task) == {:upstream_stream_failed, :response_body_too_large}
      assert_receive {:terminated, {:error, :response_body_too_large}, _}
    end

    test "#{mode}: continuation read failures return 400 quietly and close the upload" do
      owner = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      start_supervised!(
        {Task,
         fn ->
           for _ <- 1..2 do
             {:ok, socket} = :gen_tcp.accept(listener)
             send(owner, {:closed_upload, drain_upload(socket)})
             :gen_tcp.close(socket)
           end
         end}
      )

      options = config(@mode, port, :passthrough, request_body_buffer_size: 5)

      for api <- [:request, :plug] do
        conn = Plug.Test.conn(:post, "/", "first-second")
        {_, adapter_state} = conn.adapter

        conn = %{
          conn
          | adapter: {ReverseIt.FailingUploadAdapter, Map.put(adapter_state, :test_owner, self())}
        }

        assert capture_log([level: :error], fn ->
                 case api do
                   :request ->
                     assert {:error, {:request_body_read_failed, :closed}, conn, state} =
                              request(conn, options)

                     assert conn.state == :unset

                     assert_receive {:terminated, {:error, {:request_body_read_failed, :closed}},
                                     ^state}

                     refute_receive {:headers, _, _}

                   :plug ->
                     assert ReverseIt.call(conn, elem(options, 0)).status == 400
                 end
               end) == ""

        assert_receive :upload_read_failed
        assert_receive {:closed_upload, upload}, 2000
        assert upload =~ "first"
      end
    end

    test "#{mode}: response header limits include fields removed by filtering" do
      for status <- [200, 103],
          headers <- [
            "Keep-Alive: " <> String.duplicate("x", 1000) <> "\r\n",
            "Connection: x-drop\r\nX-Drop: " <> String.duplicate("x", 1000) <> "\r\n",
            "Keep-Alive: " <>
              String.duplicate("x", 40) <>
              "\r\n" <>
              "Connection: x-drop\r\nX-Drop: " <> String.duplicate("y", 40) <> "\r\n"
          ] do
        response = "HTTP/1.1 #{status} Response\r\n" <> headers <> "\r\n"

        response =
          if status == 103,
            do: response <> "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
            else: response

        {port, _} = backend(response)

        assert {:error, :response_headers_too_large, conn, state} =
                 request(
                   Plug.Test.conn(:get, "/"),
                   config(@mode, port, :passthrough, max_response_header_bytes: 100)
                 )

        assert conn.state == :unset
        assert_receive {:terminated, {:error, :response_headers_too_large}, ^state}
        refute_receive {:headers, _, _}
      end
    end

    test "#{mode}: nil and false callback rejections remain unsent failures" do
      for phase <- [:headers, :data, :end], reason <- [nil, false] do
        body = if phase == :end, do: "", else: "hello"

        {port, _} =
          backend("HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <> body)

        assert {:error, ^reason, conn, state} =
                 request(Plug.Test.conn(:get, "/"), config(@mode, port, {:reject, phase, reason}))

        assert conn.state == :unset
        assert_receive {:terminated, {:error, ^reason}, ^state}
        refute_receive {:terminated, _, _}
      end
    end

    test "#{mode}: nil and false callback rejections abort a committed response" do
      for phase <- [:data, :end], reason <- [nil, false] do
        {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
        opts = config(@mode, port, {:reject, phase, reason}, commit: :headers)

        assert catch_exit(request(Plug.Test.conn(:get, "/"), opts)) ==
                 {:upstream_stream_failed, reason}

        assert_receive {:terminated, {:error, ^reason}, _}
        refute_receive {:terminated, _, _}
      end
    end

    test "#{mode}: oversized Early Hints fail before the header callback" do
      {port, _} =
        backend(
          "HTTP/1.1 103 Early Hints\r\nX-Hint: " <>
            String.duplicate("x", 100) <> "\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        )

      assert {:error, :response_headers_too_large, conn, state} =
               request(
                 Plug.Test.conn(:get, "/"),
                 config(@mode, port, :passthrough, max_response_header_bytes: 50)
               )

      assert conn.state == :unset
      assert_receive {:terminated, {:error, :response_headers_too_large}, ^state}
      refute_receive {:headers, _, _}
    end

    test "#{mode}: invalid header callback returns fail cleanly and run cleanup" do
      for result <- [
            :invalid,
            {:stream, [], :new_state, commit: :unknown},
            {:stream, :not_headers, :new_state},
            {:buffer, :infinity, :new_state}
          ] do
        {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")

        assert {:error, {:invalid_handler_return, :handle_headers}, conn, state} =
                 request(Plug.Test.conn(:get, "/"), config(@mode, port, {:return, result}))

        assert conn.state == :unset
        assert state.mode == {:return, result}
        assert_receive {:terminated, {:error, {:invalid_handler_return, :handle_headers}}, ^state}
        refute_receive {:terminated, _, _}
        refute_receive {:data, _}
      end
    end

    test "#{mode}: a handler with no optional callbacks forwards the complete body" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
      {config, _} = config(@mode, port, :passthrough)

      assert {:ok, conn, :state} =
               ReverseIt.request(Plug.Test.conn(:get, "/"), config,
                 response_handler: {ReverseIt.HeadersOnlyHandler, :state}
               )

      assert conn.resp_body == "hello"
    end

    test "#{mode}: client body errors stay quiet through both APIs" do
      {config, _} = config(@mode, 1, :passthrough, max_request_body_size: 4)

      for {conn, reason, status} <- [
            {Plug.Test.conn(:post, "/", "12345")
             |> Plug.Conn.put_req_header("content-length", "5"), :request_body_too_large, 413},
            {Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("content-length", "invalid"),
             :invalid_content_length, 400}
          ] do
        assert capture_log(fn ->
                 assert {:error, ^reason, _, nil} = ReverseIt.request(conn, config)
                 assert ReverseIt.call(conn, config).status == status
               end) == ""
      end
    end

    test "#{mode}: the Plug logs a refused connection exactly once" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      :gen_tcp.close(listener)
      {config, _opts} = config(@mode, port, :passthrough)

      assert capture_log(fn ->
               assert {:error, _, conn, nil} =
                        ReverseIt.request(Plug.Test.conn(:get, "/"), config)

               assert conn.state == :unset
             end) == ""

      log =
        capture_log(fn ->
          assert ReverseIt.call(Plug.Test.conn(:get, "/"), config).status == 502
        end)

      assert length(Regex.scan(~r/Failed to proxy HTTP response/, log)) == 1
      assert log =~ "before commitment"
      assert log =~ "econnrefused"
    end

    test "#{mode}: handled upstream failures leave logging to the caller" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")

      assert capture_log(fn ->
               assert {:upstream_stream_failed, _} =
                        catch_exit(
                          request(Plug.Test.conn(:get, "/"), config(@mode, port, :passthrough))
                        )
             end) == ""

      assert_receive {:terminated, {:error, _}, %{bytes: 5}}
      refute_receive {:terminated, _, _}
    end

    test "#{mode}: committed upstream failures are logged once" do
      {port, _} = backend("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")
      {config, _opts} = config(@mode, port, :passthrough)

      log =
        capture_log(fn ->
          assert {:upstream_stream_failed, _} =
                   catch_exit(ReverseIt.call(Plug.Test.conn(:get, "/"), config))
        end)

      assert length(Regex.scan(~r/Failed to proxy HTTP response/, log)) == 1
      assert log =~ "after commitment"
    end
  end

  test "rejects per-request options in static configuration" do
    for opts <- [[request_body: "body"], [response_handler: {NotCompiledYet, nil}]] do
      assert_raise ArgumentError, ~r/per-request options/, fn ->
        ReverseIt.init([name: Unused, backend: "http://localhost"] ++ opts)
      end
    end
  end

  test "validates per-request types and handler modules at request time" do
    config = ReverseIt.init(name: Unused, backend: "http://localhost:1")

    for opts <- [
          [response_handler: {String, nil}],
          [response_handler: {NotCompiledYet, nil}],
          [request_body: ["iodata"]],
          [unknown: true]
        ] do
      assert_raise ArgumentError, ~r/Invalid ReverseIt request options/, fn ->
        ReverseIt.request(Plug.Test.conn(:get, "/"), config, opts)
      end
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
             request(Plug.Test.conn(:get, "/"), config)

    assert conn.state == :unset

    log =
      capture_log(fn ->
        assert ReverseIt.call(conn, elem(config, 0)).status == 504
      end)

    assert length(Regex.scan(~r/Failed to proxy HTTP response/, log)) == 1
    assert log =~ "response_headers"
    assert log =~ "timeout"
  end

  test "request/3 returns client validation errors without touching upstream" do
    conn =
      Plug.Test.conn(:get, "/long-path")
      |> Plug.Conn.put_req_header("x-one", "long-value")
      |> Plug.Conn.put_req_header("x-two", "long-value")

    for {opts, reason} <- [
          {[max_request_target_bytes: 1], :request_target_too_large},
          {[max_request_headers: 1], :too_many_request_headers},
          {[max_request_header_bytes: 1], :request_headers_too_large},
          {[max_request_header_line_bytes: 1], :request_header_line_too_large}
        ] do
      config = ReverseIt.init([name: Unused, backend: "http://localhost:1"] ++ opts)

      assert capture_log(fn ->
               assert {:error, ^reason, ^conn, nil} = ReverseIt.request(conn, config)
               assert ReverseIt.call(conn, config).status in [414, 431]
             end) == ""
    end
  end

  test "a static config is reusable with different request bodies and handler state" do
    port = Application.fetch_env!(:reverse_it, :test_backend_port)
    config = ReverseIt.init(name: ReverseIt.TestFinch, backend: "http://127.0.0.1:#{port}")
    refute Map.has_key?(config, :request_body)
    refute Map.has_key?(config, :response_handler)

    for body <- ["first", "second"] do
      state = %{owner: self(), mode: {:buffer, 1024}, request_id: body}

      assert {:buffered, response, _, ^state} =
               ReverseIt.request(Plug.Test.conn(:post, "/echo"), config,
                 request_body: body,
                 response_handler: {Handler, state}
               )

      assert Jason.decode!(response.body)["echo"] == body
    end
  end

  test "pooled HTTP/2 invokes streaming and buffering callbacks" do
    start_supervised!({ReverseIt, name: ReverseIt.HandlerHTTP2Finch, protocols: [:http2]})

    backend =
      start_supervised!(
        {Bandit, plug: {ReverseIt.TestProtocolBackend, self()}, port: 0, ip: {127, 0, 0, 1}}
      )

    config =
      ReverseIt.init(
        name: ReverseIt.HandlerHTTP2Finch,
        backend: "http://127.0.0.1:#{TestHelper.listener_port(backend)}",
        protocols: [:http2]
      )

    # Finch registers an HTTP/2 pool after its asynchronous connection setup.
    wait_for_http2("http://127.0.0.1:#{config.port}", 200)
    assert_receive {:upstream_protocol, :"HTTP/2"}

    assert {:ok, conn, %{bytes: 5}} =
             ReverseIt.request(Plug.Test.conn(:get, "/"), config,
               response_handler: {Handler, %{owner: self(), mode: :suffix}}
             )

    assert conn.resp_body == "hello!"
    assert_receive {:upstream_protocol, :"HTTP/2"}
    assert_receive {:headers, 200, _}
    refute_receive {:headers, _, _}

    assert {:buffered, %{status: 429, body: "retry"}, conn, _} =
             ReverseIt.request(Plug.Test.conn(:get, "/error"), config,
               response_handler: {Handler, %{owner: self(), mode: {:buffer, 100}}}
             )

    assert conn.state == :unset
    assert_receive {:upstream_protocol, :"HTTP/2"}
  end

  defp wait_for_http2(_url, 0), do: flunk("HTTP/2 pool did not become ready")

  defp wait_for_http2(url, attempts) do
    case Finch.request(Finch.build(:get, url), ReverseIt.HandlerHTTP2Finch) do
      {:ok, %{status: 200}} ->
        :ok

      {:error, %Finch.Error{reason: :pool_not_available}} ->
        Process.sleep(10)
        wait_for_http2(url, attempts - 1)

      result ->
        flunk("HTTP/2 connection failed: #{inspect(result)}")
    end
  end

  defp drain_upload(socket, data \\ "") do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, chunk} -> drain_upload(socket, data <> chunk)
      {:error, :closed} -> data
    end
  end

  defp config(connection_mode, port, handler_mode, opts \\ []) do
    {commit, opts} = Keyword.pop(opts, :commit)
    {request_opts, static_opts} = Keyword.split(opts, [:request_body, :response_handler])

    config =
      ReverseIt.init(
        Keyword.merge(
          [
            name: ReverseIt.TestFinch,
            backend: "http://127.0.0.1:#{port}",
            upstream_connection: connection_mode
          ],
          static_opts
        )
      )

    {config,
     Keyword.put(
       request_opts,
       :response_handler,
       {Handler, %{owner: self(), mode: handler_mode, commit: commit}}
     )}
  end

  defp request(conn, {config, opts}), do: ReverseIt.request(conn, config, opts)

  defp backend(response, remaining \\ nil) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    task =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
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
