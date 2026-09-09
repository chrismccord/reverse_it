defmodule ReverseIt.ExampleServerTest do
  use ExUnit.Case, async: false

  test "the documented startup script serves HTTP and WebSocket examples" do
    previous = Map.new(["BACKEND_PORT", "PROXY_PORT"], &{&1, System.get_env(&1)})
    System.put_env(%{"BACKEND_PORT" => "0", "PROXY_PORT" => "0"})

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    # The script's caller exits, as it does under `mix run --no-halt`.
    supervisor =
      Task.async(fn ->
        {{:ok, supervisor}, _bindings} = Code.eval_file("examples/server.exs")
        supervisor
      end)
      |> Task.await()

    on_exit(fn ->
      :ok = Supervisor.terminate_child(ReverseIt.Supervisor, ReverseIt.ExampleSupervisor)
      :ok = Supervisor.delete_child(ReverseIt.Supervisor, ReverseIt.ExampleSupervisor)
    end)

    {:proxy, proxy, _, _} = Supervisor.which_children(supervisor) |> List.keyfind(:proxy, 0)
    {:ok, {_, port}} = ThousandIsland.listener_info(proxy)

    assert %{status: 200, body: "Hello from backend!"} =
             Req.get!("http://127.0.0.1:#{port}/hello", retry: false)

    assert %{status: 404} = Req.get!("http://127.0.0.1:#{port}/nonexistent", retry: false)

    config = ReverseIt.init(backend: "http://127.0.0.1:#{port}", name: ReverseIt.ExampleFinch)
    client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}
    assert {:ok, state, _} = ReverseIt.WebSocketHandshake.open(config, client, "/ws", "")

    try do
      assert {:ok, state} = ReverseIt.WebSocketProxy.handle_in({"example", opcode: :text}, state)
      assert_receive {:tcp, _, _} = message, 2_000

      assert {:push, [{:text, "Backend echo: example"}], _} =
               ReverseIt.WebSocketProxy.handle_info(message, state)
    after
      Mint.HTTP.close(state.conn)
    end
  end
end
