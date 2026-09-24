defmodule ReverseIt.TestHandledProxy do
  @behaviour Plug

  def init({%ReverseIt.Config{}, _opts} = options), do: options

  def call(conn, {config, opts}) do
    conn =
      case ReverseIt.request(conn, config, opts) do
        {:ok, conn, _state} ->
          conn

        {:buffered, response, conn, _state} ->
          ReverseIt.send_buffered(conn, response)

        {:error, _reason, conn, _state} ->
          Plug.Conn.send_resp(conn, 502, "proxy failed")
      end

    Plug.Conn.halt(conn)
  end
end
