defmodule ReverseIt.BodylessResponseLimitTest do
  use ExUnit.Case, async: true

  for mode <- [:pooled, :one_shot] do
    @mode mode

    test "#{mode}: HEAD representation length does not count as a response body" do
      conn = proxy("HEAD", 200, @mode)
      assert conn.status == 200
      assert conn.resp_body == ""
      assert Plug.Conn.get_resp_header(conn, "content-length") == ["100"]
    end

    test "#{mode}: 304 representation length does not count as a response body" do
      conn = proxy("GET", 304, @mode)
      assert conn.status == 304
      assert conn.resp_body == ""
    end

    test "#{mode}: GET body still respects its declared length" do
      assert proxy("GET", 200, @mode).status == 502
    end
  end

  defp proxy(method, status, mode) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

         body = if method == "GET" and status == 200, do: String.duplicate("x", 100), else: ""

         :ok =
           :gen_tcp.send(socket, [
             "HTTP/1.1 #{status} Response\r\nContent-Length: 100\r\nConnection: close\r\n\r\n",
             body
           ])

         :gen_tcp.close(socket)
       end}
    )

    config =
      ReverseIt.init(
        backend: "http://127.0.0.1:#{port}",
        name: ReverseIt.TestFinch,
        upstream_connection: mode,
        max_response_body_size: 10
      )

    method |> Plug.Test.conn("/") |> ReverseIt.call(config)
  end
end
