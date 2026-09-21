defmodule ReverseIt.StreamedContentLengthTest do
  use ExUnit.Case, async: true

  test "length preservation still respects bodyless and Connection-nominated header filtering" do
    config = %{max_response_header_bytes: 1_024}
    headers = [{"Content-Length", "10"}, {"Content-Type", "application/octet-stream"}]

    assert {:ok, [{"content-length", "10"}, {"content-type", "application/octet-stream"}]} =
             ReverseIt.Headers.response_headers(headers, config)

    assert {:ok, [{"content-type", "application/octet-stream"}]} =
             ReverseIt.Headers.response_headers(headers, config, mode: :bodyless)

    assert {:ok, [{"content-type", "application/octet-stream"}]} =
             ReverseIt.Headers.response_headers(
               [{"Connection", "Content-Length"} | headers],
               config
             )
  end

  for mode <- [:pooled, :one_shot] do
    @mode mode

    for status <- [200, 206], limit <- [:infinity, 10] do
      @status status
      @limit limit

      test "#{mode}: streams #{status} with Content-Length and body limit #{limit}" do
        range_header = if @status == 206, do: "Content-Range: bytes 0-9/20\r\n", else: ""

        {port, upstream} =
          start_proxy(
            [upstream_connection: @mode, max_response_body_size: @limit],
            [
              "HTTP/1.1 #{@status} Response\r\n",
              "Content-Length: 10\r\n",
              "Content-Type: application/octet-stream\r\n",
              "Content-Disposition: attachment; filename=download.bin\r\n",
              "Accept-Ranges: bytes\r\n",
              range_header,
              "Connection: close\r\n\r\n",
              "hello"
            ],
            "world"
          )

        {:ok, socket} =
          :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :http_bin])

        on_exit(fn -> :gen_tcp.close(socket) end)

        :ok =
          :gen_tcp.send(socket, [
            "GET /download HTTP/1.1\r\nHost: localhost\r\n",
            "Accept-Encoding: gzip\r\nConnection: close\r\n\r\n"
          ])

        assert {:ok, {:http_response, _, @status, _}} = :gen_tcp.recv(socket, 0, 5_000)
        headers = recv_headers(socket)
        assert headers["content-length"] == "10"
        refute Map.has_key?(headers, "transfer-encoding")
        refute Map.has_key?(headers, "content-encoding")
        assert headers["content-disposition"] == "attachment; filename=download.bin"
        assert headers["accept-ranges"] == "bytes"

        if @status == 206 do
          assert headers["content-range"] == "bytes 0-9/20"
        end

        :ok = :inet.setopts(socket, packet: :raw)

        # The upstream cannot finish until the client receives the first bytes.
        # This catches buffering as well as unwanted chunk framing or compression.
        assert {:ok, "hello"} = :gen_tcp.recv(socket, 5, 5_000)
        send(upstream, :finish)
        assert {:ok, "world"} = :gen_tcp.recv(socket, 5, 5_000)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      end
    end

    test "#{mode}: responses without a length still use chunked transfer encoding" do
      {port, _upstream} =
        start_proxy(
          [upstream_connection: @mode],
          [
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n",
            "Connection: close\r\n\r\n",
            "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n"
          ]
        )

      response = Req.get!("http://127.0.0.1:#{port}/download", compressed: false, retry: false)

      assert response.status == 200
      assert response.body == "helloworld"
      assert response.headers["transfer-encoding"] == ["chunked"]
      refute Map.has_key?(response.headers, "content-length")
    end

    test "#{mode}: preserves a zero length without adding chunked framing" do
      {port, _upstream} =
        start_proxy(
          [upstream_connection: @mode],
          "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )

      response = Req.get!("http://127.0.0.1:#{port}/download", compressed: false, retry: false)

      assert response.status == 200
      assert response.body == ""
      assert response.headers["content-length"] == ["0"]
      refute Map.has_key?(response.headers, "transfer-encoding")
    end
  end

  defp start_proxy(opts, response, remaining_body \\ "") do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    {:ok, backend_port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    upstream =
      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
           :ok = :gen_tcp.send(socket, response)

           if remaining_body != "" do
             receive do
               :finish -> :ok = :gen_tcp.send(socket, remaining_body)
             after
               10_000 -> raise "client did not receive the first response bytes"
             end
           end

           :gen_tcp.close(socket)
         end}
      )

    proxy =
      start_supervised!(
        {Bandit,
         plug:
           {ReverseIt,
            Keyword.merge(
              [name: ReverseIt.TestFinch, backend: "http://127.0.0.1:#{backend_port}"],
              opts
            )},
         port: 0}
      )

    {TestHelper.listener_port(proxy), upstream}
  end

  defp recv_headers(socket, headers \\ %{}) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        recv_headers(socket, Map.put(headers, String.downcase(to_string(name)), value))

      {:ok, :http_eoh} ->
        headers
    end
  end
end
