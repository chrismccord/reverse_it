# Run from the project root: MIX_ENV=test mix run --no-halt examples/server.exs
# The example backend is compiled from test/support; test_helper.exs is not loaded.
backend_port = System.get_env("BACKEND_PORT", "4001") |> String.to_integer()
proxy_port = System.get_env("PROXY_PORT", "4000") |> String.to_integer()

{:ok, supervisor} =
  Supervisor.start_child(ReverseIt.Supervisor, %{
    id: ReverseIt.ExampleSupervisor,
    type: :supervisor,
    start:
      {Supervisor, :start_link,
       [
         [
           {ReverseIt, name: ReverseIt.ExampleFinch},
           Supervisor.child_spec(
             {Bandit, plug: ReverseIt.TestBackend, port: backend_port, ip: {127, 0, 0, 1}},
             id: :backend
           )
         ],
         [strategy: :one_for_one]
       ]}
  })

{:backend, backend, _, _} =
  supervisor |> Supervisor.which_children() |> List.keyfind(:backend, 0)

{:ok, {_, backend_port}} = ThousandIsland.listener_info(backend)

{:ok, proxy} =
  Supervisor.start_child(
    supervisor,
    Supervisor.child_spec(
      {Bandit,
       plug:
         {ReverseIt, backend: "http://127.0.0.1:#{backend_port}", name: ReverseIt.ExampleFinch},
       port: proxy_port,
       ip: {127, 0, 0, 1}},
      id: :proxy
    )
  )

{:ok, {_, proxy_port}} = ThousandIsland.listener_info(proxy)
IO.puts("Example backend: http://localhost:#{backend_port}")
IO.puts("Example proxy: http://localhost:#{proxy_port} (WebSocket: /ws)")
{:ok, supervisor}
