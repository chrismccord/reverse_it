ExUnit.start()

# Wait for test servers to be ready before running tests
defmodule TestHelper do
  def unix_socket_path do
    # Relative paths stay within Unix socket length limits even in deep checkouts
    # or when the OS supplies a long temporary directory (notably on macOS).
    File.mkdir_p!("tmp")
    Path.join("tmp", "reverse-it-#{System.pid()}-#{System.unique_integer([:positive])}.sock")
  end

  def wait_for_server(url, retries \\ 100) do
    # Use Req with disabled retries for faster polling
    case Req.get(url, retry: false, connect_options: [timeout: 100]) do
      {:ok, _response} ->
        :ok

      {:error, _reason} ->
        if retries > 0 do
          Process.sleep(50)
          wait_for_server(url, retries - 1)
        else
          raise "Server at #{url} not ready after 5 seconds"
        end
    end
  end

  @doc """
  Returns the TCP port already bound by a running Bandit listener.
  """
  def listener_port(pid) do
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end
end

# Ensure application is started (but no test servers yet)
{:ok, _} = Application.ensure_all_started(:reverse_it)

# Explicitly start test servers under the supervisor
IO.puts("Starting test servers...")

# Start ReverseIt Finch pool
{:ok, _finch_pid} =
  Supervisor.start_child(
    ReverseIt.Supervisor,
    {ReverseIt, name: ReverseIt.TestFinch}
  )

# Start backend server on dynamically allocated port
{:ok, backend_pid} =
  Supervisor.start_child(
    ReverseIt.Supervisor,
    {Bandit,
     plug: ReverseIt.TestBackend,
     scheme: :http,
     port: 0,
     thousand_island_options: [silent_terminate_on_error: true]}
  )

backend_port = TestHelper.listener_port(backend_pid)
Application.put_env(:reverse_it, :test_backend_port, backend_port)

# Start proxy server on dynamically allocated port
{:ok, proxy_pid} =
  Supervisor.start_child(
    ReverseIt.Supervisor,
    {Bandit,
     plug: ReverseIt.TestProxy,
     scheme: :http,
     port: 0,
     thousand_island_options: [silent_terminate_on_error: true]}
  )

proxy_port = TestHelper.listener_port(proxy_pid)
Application.put_env(:reverse_it, :test_proxy_port, proxy_port)

# Wait for both servers to be ready
IO.puts("Waiting for test servers to start...")

try do
  TestHelper.wait_for_server("http://localhost:#{backend_port}/hello")
  IO.puts("Backend server ready on port #{backend_port}")

  TestHelper.wait_for_server("http://localhost:#{proxy_port}/hello")
  IO.puts("Proxy server ready on port #{proxy_port}")

  IO.puts("All test servers ready!")
rescue
  e ->
    IO.puts("Failed to start test servers: #{inspect(e)}")
    IO.puts("\nError: #{inspect(e)}")
    System.halt(1)
end
