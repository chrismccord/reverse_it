ExUnit.start()

# Wait for test servers to be ready before running tests
defmodule TestHelper do
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
  Finds an available port by opening a socket on port 0, which assigns a random available port.
  """
  def find_available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

# Ensure application is started (but no test servers yet)
{:ok, _} = Application.ensure_all_started(:reverse_it)

# Find available ports
backend_port = TestHelper.find_available_port()
proxy_port = TestHelper.find_available_port()

# Store ports in application environment so tests can access them
Application.put_env(:reverse_it, :test_backend_port, backend_port)
Application.put_env(:reverse_it, :test_proxy_port, proxy_port)

# Explicitly start test servers under the supervisor
IO.puts("Starting test servers...")
IO.puts("Backend port: #{backend_port}")
IO.puts("Proxy port: #{proxy_port}")

# Start ReverseIt Finch pool
{:ok, _finch_pid} =
  Supervisor.start_child(
    ReverseIt.Supervisor,
    {ReverseIt, name: ReverseIt.TestFinch}
  )

# Start backend server on dynamically allocated port
{:ok, _backend_pid} =
  Supervisor.start_child(
    ReverseIt.Supervisor,
    {Bandit, plug: ReverseIt.TestBackend, scheme: :http, port: backend_port}
  )

# Start proxy server on dynamically allocated port
{:ok, _proxy_pid} =
  Supervisor.start_child(
    ReverseIt.Supervisor,
    {Bandit, plug: ReverseIt.TestProxy, scheme: :http, port: proxy_port}
  )

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
