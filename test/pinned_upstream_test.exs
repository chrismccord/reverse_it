defmodule ReverseIt.PinnedUpstreamTest do
  # TLS tests temporarily install a test trust store, restoring the original.
  use ExUnit.Case, async: false

  test "pinning requires a valid address, one-shot transport, and no Unix socket" do
    for opts <- [
          [connect_ip: "127.0.0.1", upstream_connection: :one_shot],
          [connect_ip: {256, 0, 0, 1}, upstream_connection: :one_shot],
          [connect_ip: {127, 0, 0, 1}],
          [
            connect_ip: {127, 0, 0, 1},
            upstream_connection: :one_shot,
            unix_socket: "/tmp/test.sock"
          ]
        ] do
      assert_raise ArgumentError, ~r/connect_ip/, fn ->
        ReverseIt.init([name: Unused, backend: "http://connector.test"] ++ opts)
      end
    end
  end

  test "pinned HTTP uses the original authority without resolving it" do
    port = Application.fetch_env!(:reverse_it, :test_backend_port)
    config = config("http://does-not-resolve.invalid:#{port}")

    assert {:buffered, response, _, _} =
             request(Plug.Test.conn(:get, "/headers"), config)

    assert Jason.decode!(response.body)["headers"]["host"] == "does-not-resolve.invalid:#{port}"
  end

  @tag :tmp_dir
  test "pinned HTTPS verifies the original hostname and sends its SNI and Host", %{tmp_dir: dir} do
    tls = trusted_tls(dir)
    port = tls_backend(tls)

    assert {:buffered, %{body: "ok"}, _, _} =
             request(
               Plug.Test.conn(:get, "/"),
               config("https://connector.test:#{port}")
             )

    assert_receive {:sni, ~c"connector.test"}, 2000
    assert_receive {:upstream_request, request}, 2000
    assert String.downcase(request) =~ "host: connector.test:#{port}\r\n"
  end

  @tag :tmp_dir
  test "pinned HTTPS still rejects a certificate for another hostname", %{tmp_dir: dir} do
    port = tls_backend(trusted_tls(dir))

    assert {:error, %Mint.TransportError{reason: {:tls_alert, _}}, conn, _} =
             request(Plug.Test.conn(:get, "/"), config("https://wrong.test:#{port}"))

    assert conn.state == :unset
    refute_receive {:upstream_request, _}
  end

  test "IPv6 pinning selects IPv6 transport while retaining DNS authority" do
    config =
      ReverseIt.init(
        name: Unused,
        backend: "https://connector.test",
        connect_ip: {0, 0, 0, 0, 0, 0, 0, 1},
        upstream_connection: :one_shot
      )

    assert ReverseIt.Config.transport_opts(config)[:inet6]
    assert config.host == "connector.test"
  end

  test "pinned WebSocket uses the backend authority without resolving its hostname" do
    port = Application.fetch_env!(:reverse_it, :test_backend_port)
    config = config("ws://does-not-resolve.invalid:#{port}")
    client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}
    assert {:ok, state, _headers} = ReverseIt.WebSocketHandshake.open(config, client, "/ws", "")

    try do
      assert {:ok, state} = ReverseIt.WebSocketProxy.handle_in({"pinned", opcode: :text}, state)
      assert_receive {:tcp, _, _} = message, 2000

      assert {:push, [{:text, "Backend echo: pinned"}], _state} =
               ReverseIt.WebSocketProxy.handle_info(message, state)
    after
      Mint.HTTP.close(state.conn)
    end
  end

  defp config(url) do
    ReverseIt.init(
      name: ReverseIt.TestFinch,
      backend: url,
      connect_ip: {127, 0, 0, 1},
      upstream_connection: :one_shot
    )
  end

  defp request(conn, config) do
    ReverseIt.request(conn, config,
      response_handler: {ReverseIt.TestResponseHandler, %{owner: self(), mode: {:buffer, 4096}}}
    )
  end

  defp trusted_tls(dir) do
    tls =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65537}],
        peer: [
          key: {:rsa, 2048, 65537},
          extensions: [
            {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"connector.test"]}
          ]
        ]
      })

    previous = Enum.map(:public_key.cacerts_get(), fn {:cert, der, _} -> der end)
    previous_path = Path.join(dir, "previous.pem")
    test_path = Path.join(dir, "test.pem")
    write_certs(previous_path, previous)
    write_certs(test_path, Keyword.fetch!(tls, :cacerts))
    on_exit(fn -> :public_key.cacerts_load(String.to_charlist(previous_path)) end)
    :ok = :public_key.cacerts_load(String.to_charlist(test_path))
    tls
  end

  defp write_certs(path, certs) do
    File.write!(
      path,
      :public_key.pem_encode(Enum.map(certs, &{:Certificate, &1, :not_encrypted}))
    )
  end

  defp tls_backend(tls) do
    owner = self()

    sni = fn hostname ->
      send(owner, {:sni, hostname})
      []
    end

    {:ok, listener} = :ssl.listen(0, [mode: :binary, active: false, sni_fun: sni] ++ tls)
    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :ssl.transport_accept(listener, 2000)

         case :ssl.handshake(socket, 2000) do
           {:ok, socket} ->
             {:ok, request} = :ssl.recv(socket, 0, 2000)
             send(owner, {:upstream_request, request})
             :ok = :ssl.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
             :ssl.close(socket)

           {:error, _} ->
             :ssl.close(socket)
         end
       end}
    )

    port
  end
end
