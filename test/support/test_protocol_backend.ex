defmodule ReverseIt.TestProtocolBackend do
  @behaviour Plug

  def init(owner), do: owner

  def call(conn, owner) do
    send(owner, {:upstream_protocol, Plug.Conn.get_http_protocol(conn)})

    if conn.request_path == "/error" do
      Plug.Conn.send_resp(conn, 429, "retry")
    else
      Plug.Conn.send_resp(conn, 200, "hello")
    end
  end
end
