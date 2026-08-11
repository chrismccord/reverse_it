defmodule ReverseIt.Headers do
  @moduledoc false

  @hop_by_hop_headers MapSet.new([
                        "connection",
                        "keep-alive",
                        "proxy-authenticate",
                        "proxy-authorization",
                        "te",
                        "trailer",
                        "transfer-encoding",
                        "upgrade",
                        "proxy-connection"
                      ])

  @websocket_headers MapSet.new([
                       "sec-websocket-accept",
                       "sec-websocket-extensions",
                       "sec-websocket-key",
                       "sec-websocket-protocol",
                       "sec-websocket-version"
                     ])

  @content_headers MapSet.new([
                     "content-length",
                     "transfer-encoding"
                   ])

  @consumed_request_headers MapSet.new(["expect"])

  @doc """
  Builds safe backend HTTP request headers from a Plug connection.
  """
  def request_headers(conn, config) do
    conn.req_headers
    |> normalize_headers()
    |> strip_hop_by_hop()
    |> reject_header_names(@consumed_request_headers)
    |> remove_configured_headers(config)
    |> add_forwarded_headers(config, forwarded_info(conn))
    |> replace_host_header(config)
    |> add_configured_headers(config)
  end

  @doc """
  Builds safe backend WebSocket upgrade headers from client request metadata.
  """
  def websocket_request_headers(client, config) do
    headers = normalize_headers(client.headers)

    protocols = Enum.filter(headers, fn {name, _value} -> name == "sec-websocket-protocol" end)

    headers
    |> strip_hop_by_hop()
    |> reject_header_names(@websocket_headers)
    |> remove_configured_headers(config)
    |> add_forwarded_headers(config, client)
    |> replace_host_header(config)
    |> add_websocket_protocols(protocols, config)
    |> add_configured_headers(config)
  end

  @doc """
  Sanitizes backend response headers before sending them to the client.
  """
  def response_headers(headers, config, opts \\ []) do
    mode = Keyword.get(opts, :mode, :identity)

    headers =
      headers
      |> normalize_headers()
      |> strip_hop_by_hop()
      |> maybe_strip_content_headers(mode)

    with :ok <- validate_header_block_size(headers, config.max_response_header_bytes),
         :ok <- validate_headers(headers) do
      {:ok, headers}
    end
  end

  @doc """
  Validates the client request metadata exposed by Plug after server parsing.
  """
  def validate_client_request(conn, config) do
    target =
      case conn.query_string do
        "" -> conn.request_path
        query -> conn.request_path <> "?" <> query
      end

    cond do
      byte_size(target) > config.max_request_target_bytes ->
        {:error, :request_target_too_large}

      length(conn.req_headers) > config.max_request_headers ->
        {:error, :too_many_request_headers}

      header_block_size(conn.req_headers) > config.max_request_header_bytes ->
        {:error, :request_headers_too_large}

      Enum.any?(conn.req_headers, fn {name, value} ->
        byte_size(name) + 2 + byte_size(value) > config.max_request_header_line_bytes
      end) ->
        {:error, :request_header_line_too_large}

      true ->
        :ok
    end
  end

  def put_response_headers(conn, headers) do
    conn
    |> Map.put(:resp_headers, [])
    |> Plug.Conn.prepend_resp_headers(headers)
  end

  def backend_host(config) do
    if config.port in [80, 443], do: config.host, else: "#{config.host}:#{config.port}"
  end

  defp normalize_headers(headers) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        [{String.downcase(name), value}]

      _other ->
        []
    end)
  end

  defp strip_hop_by_hop(headers) do
    connection_tokens =
      headers
      |> Enum.filter(fn {name, _value} -> name == "connection" end)
      |> Enum.flat_map(fn {_name, value} -> header_tokens(value) end)
      |> MapSet.new()

    blocked = MapSet.union(@hop_by_hop_headers, connection_tokens)
    reject_header_names(headers, blocked)
  end

  defp reject_header_names(headers, blocked) do
    Enum.reject(headers, fn {name, _value} -> MapSet.member?(blocked, name) end)
  end

  defp remove_configured_headers(headers, config) do
    reject_header_names(headers, config.remove_headers)
  end

  defp add_configured_headers(headers, config) do
    Enum.reduce(config.add_headers, headers, fn {name, value}, acc ->
      List.keystore(acc, name, 0, {name, value})
    end)
  end

  defp add_websocket_protocols(headers, protocols, config) do
    configured? =
      Enum.any?(config.add_headers, fn {name, _value} -> name == "sec-websocket-protocol" end)

    if configured? or MapSet.member?(config.remove_headers, "sec-websocket-protocol") do
      headers
    else
      headers ++ protocols
    end
  end

  defp add_forwarded_headers(headers, %{forwarded_headers: false}, _client), do: headers

  defp add_forwarded_headers(headers, %{forwarded_headers: :replace}, client) do
    headers
    |> List.keystore("x-forwarded-for", 0, {"x-forwarded-for", client.remote_ip})
    |> List.keystore("x-forwarded-proto", 0, {"x-forwarded-proto", client.scheme})
    |> maybe_add_forwarded_host(client.host)
  end

  defp add_forwarded_headers(headers, %{forwarded_headers: :append}, client) do
    forwarded_for =
      case List.keyfind(headers, "x-forwarded-for", 0) do
        {_, existing} -> existing <> ", " <> client.remote_ip
        nil -> client.remote_ip
      end

    headers
    |> List.keystore("x-forwarded-for", 0, {"x-forwarded-for", forwarded_for})
    |> List.keystore("x-forwarded-proto", 0, {"x-forwarded-proto", client.scheme})
    |> maybe_add_forwarded_host(client.host)
  end

  defp maybe_add_forwarded_host(headers, nil), do: headers

  defp maybe_add_forwarded_host(headers, host) do
    List.keystore(headers, "x-forwarded-host", 0, {"x-forwarded-host", host})
  end

  defp replace_host_header(headers, %{preserve_host_header: true}), do: headers

  defp replace_host_header(headers, config) do
    [{"host", backend_host(config)} | List.keydelete(headers, "host", 0)]
  end

  defp forwarded_info(conn) do
    %{
      remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      scheme: Atom.to_string(conn.scheme),
      host: forwarded_host(conn)
    }
  end

  defp forwarded_host(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [host | _] -> host
      [] -> nil
    end
  end

  defp maybe_strip_content_headers(headers, :chunked),
    do: reject_header_names(headers, @content_headers)

  defp maybe_strip_content_headers(headers, _mode), do: headers

  defp validate_header_block_size(headers, max_bytes) do
    if header_block_size(headers) > max_bytes do
      {:error, :response_headers_too_large}
    else
      :ok
    end
  end

  defp validate_headers(headers) do
    Enum.reduce_while(headers, :ok, fn
      {name, value}, :ok when is_binary(name) and is_binary(value) ->
        if valid_header?(name, value) do
          {:cont, :ok}
        else
          {:halt, {:error, :invalid_response_header}}
        end

      _other, :ok ->
        {:halt, {:error, :invalid_response_header}}
    end)
  end

  defp valid_header?(name, value) do
    :binary.match(name, [":", "\n", "\r", "\x00"]) == :nomatch and
      :binary.match(value, ["\n", "\r", "\x00"]) == :nomatch
  end

  defp header_block_size(headers) do
    Enum.reduce(headers, 0, fn {name, value}, total ->
      total + byte_size(name) + 2 + byte_size(value)
    end)
  end

  defp header_tokens(value) do
    value
    |> Plug.Conn.Utils.list()
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
