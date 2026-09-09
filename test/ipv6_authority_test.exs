defmodule ReverseIt.IPv6AuthorityTest do
  use ExUnit.Case, async: true

  test "authorities bracket IPv6 and omit only the scheme's default port" do
    for {backend, expected} <- [
          {"http://[::1]", "[::1]"},
          {"https://[::1]", "[::1]"},
          {"ws://[::1]:443", "[::1]:443"},
          {"wss://[::1]:80", "[::1]:80"},
          {"http://example.com:443", "example.com:443"},
          {"https://example.com:80", "example.com:80"},
          {"http://127.0.0.1:4000", "127.0.0.1:4000"}
        ] do
      config = ReverseIt.init(backend: backend, name: ReverseIt.TestFinch)
      assert ReverseIt.Headers.backend_host(config) == expected

      client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}
      assert {"host", expected} in ReverseIt.Headers.websocket_request_headers(client, config)
    end
  end

  for mode <- [:pooled, :one_shot] do
    @mode mode
    test "#{mode}: IPv6 backend receives the original target and a valid Host" do
      start_supervised!({ReverseIt, name: __MODULE__, inet6: true})

      {:ok, listener} =
        :gen_tcp.listen(0, [:inet6, :binary, active: false, ip: {0, 0, 0, 0, 0, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)
      parent = self()

      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
           send(parent, {:request, request})
           :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
           :gen_tcp.close(socket)
         end}
      )

      config =
        ReverseIt.init(
          backend: "http://[::1]:#{port}",
          name: __MODULE__,
          upstream_connection: @mode
        )

      conn = Plug.Test.conn("GET", "/a%2Fb?x=%2F") |> ReverseIt.call(config)
      assert conn.status == 200
      assert_receive {:request, request}
      assert request =~ "GET /a%2Fb?x=%2F HTTP/1.1\r\n"
      assert request =~ "host: [::1]:#{port}\r\n"
    end
  end
end
