defmodule ReverseIt.TestProxy do
  @moduledoc """
  Test proxy server that forwards requests to the backend.
  Uses a custom plug to dynamically configure ReverseIt with runtime port.
  """

  use Plug.Router

  require Logger

  plug(:match)
  plug(:proxy)
  plug(:dispatch)

  # Dynamic proxy plug that gets backend port at runtime
  defp proxy(conn, _opts) do
    backend_port = Application.get_env(:reverse_it, :test_backend_port)

    ReverseIt.call(
      conn,
      ReverseIt.init(proxy_opts(conn.request_path, backend_port))
    )
  end

  defp proxy_opts("/limited" <> _rest, backend_port) do
    base_opts(backend_port,
      strip_path: "/limited",
      max_request_body_size: 1024,
      request_body_buffer_size: 512,
      request_body_chunk_size: 256
    )
  end

  defp proxy_opts("/response-limit" <> _rest, backend_port) do
    base_opts(backend_port,
      strip_path: "/response-limit",
      max_response_body_size: 1024
    )
  end

  defp proxy_opts("/replace-forwarded" <> _rest, backend_port) do
    base_opts(backend_port,
      strip_path: "/replace-forwarded",
      forwarded_headers: :replace
    )
  end

  defp proxy_opts("/tiny-ws" <> _rest, backend_port) do
    base_opts(backend_port,
      strip_path: "/tiny-ws",
      max_websocket_frame_size: 128,
      max_websocket_pending_bytes: 64,
      max_websocket_pending_frames: 1
    )
  end

  defp proxy_opts(_path, backend_port), do: base_opts(backend_port)

  defp base_opts(backend_port, extra \\ []) do
    Keyword.merge(
      [
        name: ReverseIt.TestFinch,
        backend: "http://localhost:#{backend_port}"
      ],
      extra
    )
  end

  # This should never be reached as ReverseIt halts the connection
  match _ do
    send_resp(conn, 500, "Proxy failed")
  end
end
