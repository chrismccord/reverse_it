defmodule ReverseIt.TestHandledProxy do
  @behaviour Plug
  def init(%ReverseIt.Config{} = config), do: config
  def init(opts), do: ReverseIt.init(opts)

  def call(conn, config) do
    case ReverseIt.request(conn, config) do
      {:ok, conn, _state} ->
        conn

      {:buffered, response, conn, _state} ->
        Plug.Conn.send_resp(conn, response.status, response.body)

      {:error, _reason, conn, _state} ->
        Plug.Conn.send_resp(conn, 502, "proxy failed")
    end
  end
end
