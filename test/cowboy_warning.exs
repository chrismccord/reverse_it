# Run with `MIX_ENV=prod elixir test/cowboy_warning.exs`.
# Keep Cowboy isolated from the library's dependencies and normal test application.
Mix.install(
  [
    {:reverse_it, path: Path.expand("..", __DIR__)},
    {:plug_cowboy, "~> 2.9"},
    {:bandit, "~> 1.12"}
  ],
  lockfile: Path.expand("../mix.lock", __DIR__)
)

ExUnit.start()

defmodule ReverseIt.CowboyWarningTest.Backend do
  def init(opts), do: opts
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 403, "no upgrade")
end

defmodule ReverseIt.CowboyWarningTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  setup do
    start_supervised!({ReverseIt, name: __MODULE__.Finch})

    backend =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: __MODULE__.Backend, port: 0, ip: {127, 0, 0, 1}},
          id: :backend
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(backend)
    %{opts: [backend: "http://127.0.0.1:#{port}", name: __MODULE__.Finch]}
  end

  test "Cowboy WebSocket attempts warn even when the backend rejects the upgrade", %{opts: opts} do
    port = cowboy(opts)

    log = capture_log([level: :warning], fn -> request(port, websocket_headers()) end)
    assert log =~ "WebSocket proxying is unsupported with Cowboy"
    assert log =~ "Use Bandit"
  end

  test "ordinary Cowboy HTTP requests do not warn", %{opts: opts} do
    port = cowboy(opts)
    assert capture_log([level: :warning], fn -> request(port, []) end) == ""
  end

  test "Bandit WebSocket requests do not warn even with Cowboy installed", %{opts: opts} do
    proxy =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {ReverseIt, opts}, port: 0, ip: {127, 0, 0, 1}},
          id: :proxy
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(proxy)
    assert capture_log([level: :warning], fn -> request(port, websocket_headers()) end) == ""
  end

  defp cowboy(opts) do
    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {ReverseIt, opts},
        options: [port: 0, ip: {127, 0, 0, 1}, ref: __MODULE__.Cowboy]
      )
    )

    :ranch.get_port(__MODULE__.Cowboy)
  end

  defp request(port, headers) do
    assert {:ok, %Finch.Response{status: 403, body: "no upgrade"}} =
             Finch.build(:get, "http://127.0.0.1:#{port}/", headers)
             |> Finch.request(__MODULE__.Finch)
  end

  defp websocket_headers do
    [
      {"connection", "upgrade"},
      {"upgrade", "websocket"},
      {"sec-websocket-version", "13"},
      {"sec-websocket-key", Base.encode64("0123456789abcdef")}
    ]
  end
end
