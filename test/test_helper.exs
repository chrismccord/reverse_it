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
end

# Ensure application is started
{:ok, _} = Application.ensure_all_started(:reverse_it)

# Give servers a moment to initialize
Process.sleep(200)

# Wait for both servers to be ready
IO.puts("Waiting for test servers to start...")

try do
  TestHelper.wait_for_server("http://localhost:4001/hello")
  IO.puts("Backend server ready on port 4001")

  TestHelper.wait_for_server("http://localhost:4000/hello")
  IO.puts("Proxy server ready on port 4000")

  IO.puts("All test servers ready!")
rescue
  e ->
    IO.puts("Failed to start test servers: #{inspect(e)}")
    IO.puts("\nMake sure ports 4000 and 4001 are not already in use.")
    System.halt(1)
end
