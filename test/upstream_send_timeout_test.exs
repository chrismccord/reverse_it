defmodule ReverseIt.UpstreamSendTimeoutTest do
  use ExUnit.Case, async: true

  test "direct and pooled connections default to bounded writes and close on timeout" do
    config = ReverseIt.init(backend: "http://localhost", name: __MODULE__.Finch)
    direct = ReverseIt.Config.transport_opts(config)
    assert direct[:send_timeout] == 55_000
    assert direct[:send_timeout_close] == true

    %{start: {Finch, :start_link, [opts]}} = ReverseIt.child_spec(name: __MODULE__.Finch)
    pooled = opts[:pools].default[:conn_opts][:transport_opts]
    assert pooled[:send_timeout] == 55_000
    assert pooled[:send_timeout_close] == true

    for timeout <- [:infinity, -1, nil] do
      assert {:error, "upstream_send_timeout must be a non-negative integer"} =
               ReverseIt.Config.parse(
                 backend: "http://localhost",
                 name: __MODULE__.Finch,
                 upstream_send_timeout: timeout
               )
    end
  end

  for mode <- [:pooled, :one_shot] do
    @mode mode

    test "#{mode}: a backend that stops reading cannot pin a streamed upload" do
      start_supervised!(
        {ReverseIt, name: __MODULE__.Finch, pool_size: 1, upstream_send_timeout: 50}
      )

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, recbuf: 1_024])

      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      backend =
        start_supervised!({Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           :ok = :gen_tcp.send(socket, "HTTP/1.1 413 Too Large\r\nContent-Length: 0\r\n\r\n")

           # Do not consume the upload. Only resume once the proxy has returned.
           receive do
             :resume -> :gen_tcp.close(socket)
           end

           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
           :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
           :gen_tcp.close(socket)
         end})

      config =
        ReverseIt.init(
          backend: "http://127.0.0.1:#{port}",
          name: __MODULE__.Finch,
          upstream_connection: @mode,
          upstream_send_timeout: 50,
          upstream_idle_timeout: 5_000,
          response_header_timeout: 5_000,
          request_body_buffer_size: 1_024
        )

      request =
        Task.async(fn ->
          Plug.Test.conn("POST", "/", :binary.copy("x", 16_000_000))
          |> ReverseIt.call(config)
        end)

      try do
        assert {:ok, %Plug.Conn{status: 502}} = Task.yield(request, 2_000)
      after
        Task.shutdown(request, :brutal_kill)
      end

      send(backend, :resume)

      # With a one-slot pool this also checks that the failed request released its slot.
      assert %Plug.Conn{status: 200} = Plug.Test.conn("GET", "/") |> ReverseIt.call(config)
    end
  end
end
