defmodule ReverseIt.BodylessHTTP2Test do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  for {method, status} <- [{:head, 200}, {:get, 204}, {:get, 304}, {:get, 101}] do
    @method method
    @status status

    test "#{method} #{status}: discarded DATA is bounded and the upstream stream is cancelled" do
      start_supervised!({ReverseIt, name: __MODULE__.Finch, protocols: [:http2]})
      owner = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      # A conforming HTTP server will not send these forbidden bodies. Use raw
      # HTTP/2 frames to exercise the DATA that Mint exposes even for HEAD/204/304.
      backend =
        start_supervised!(
          {Task,
           fn ->
             {:ok, socket} = :gen_tcp.accept(listener)
             {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} = :gen_tcp.recv(socket, 24, 2000)
             :ok = :gen_tcp.send(socket, frame(4, 0, 0, ""))

             for _ <- 1..3 do
               {1, stream_id, _payload} = await_frame(socket, 1)

               {headers, _} =
                 HPAX.encode(:no_store, [{":status", to_string(@status)}], HPAX.new(4096))

               :ok =
                 :gen_tcp.send(socket, [
                   frame(1, 4, stream_id, headers),
                   frame(0, 0, stream_id, "1234")
                 ])

               send(owner, :body_at_limit)

               receive do
                 :overflow -> :ok = :gen_tcp.send(socket, frame(0, 0, stream_id, "5"))
               after
                 2000 -> raise "proxy did not wait at the byte limit"
               end

               {3, ^stream_id, <<8::32>>} = await_frame(socket, 3)
               send(owner, :upstream_cancelled)
             end

             :gen_tcp.close(socket)
           end}
        )

      config =
        ReverseIt.init(
          name: __MODULE__.Finch,
          backend: "http://127.0.0.1:#{port}",
          protocols: [:http2],
          max_response_body_size: 4
        )

      for handler_mode <- [nil, :passthrough, {:buffer, 0}] do
        opts =
          if handler_mode do
            [
              response_handler:
                {ReverseIt.TestResponseHandler, %{owner: self(), mode: handler_mode}}
            ]
          else
            []
          end

        task = Task.async(fn -> request(@method, config, opts, 200) end)
        assert_receive :body_at_limit, 2000
        assert Task.yield(task, 20) == nil
        refute_receive {:data, _}
        send(backend, :overflow)
        assert {:error, :response_body_too_large, conn, _} = Task.await(task)
        assert conn.state == :unset
        assert_receive :upstream_cancelled, 2000
      end
    end
  end

  defp request(_method, _config, _opts, 0), do: flunk("HTTP/2 pool did not become ready")

  defp request(method, config, opts, attempts) do
    case ReverseIt.request(Plug.Test.conn(method, "/"), config, opts) do
      {:error, %Finch.Error{reason: :pool_not_available}, _, _} ->
        Process.sleep(10)
        request(method, config, opts, attempts - 1)

      result ->
        result
    end
  end

  defp frame(type, flags, stream_id, payload) do
    payload = IO.iodata_to_binary(payload)
    [<<byte_size(payload)::24, type::8, flags::8, 0::1, stream_id::31>>, payload]
  end

  defp await_frame(socket, wanted_type) do
    {:ok, <<length::24, type::8, flags::8, _::1, stream_id::31>>} = :gen_tcp.recv(socket, 9, 2000)

    payload =
      if length == 0 do
        ""
      else
        {:ok, payload} = :gen_tcp.recv(socket, length, 2000)
        payload
      end

    if type == 4 and flags == 0, do: :gen_tcp.send(socket, frame(4, 1, 0, ""))

    if type == wanted_type, do: {type, stream_id, payload}, else: await_frame(socket, wanted_type)
  end
end
