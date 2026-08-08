defmodule ReverseIt.WebSocketHandshake do
  @moduledoc false

  alias ReverseIt.{Config, Headers, Upstream, WebSocketProxy}

  @client_managed_headers MapSet.new([
                            "sec-websocket-accept",
                            "sec-websocket-extensions",
                            "sec-websocket-key",
                            "sec-websocket-version"
                          ])

  def open(%Config{} = config, client, path, query_string) do
    with {:ok, conn} <- Upstream.connect(config) do
      target_path = target_path(config, path, query_string)
      headers = Headers.websocket_request_headers(client, config)

      case Mint.WebSocket.upgrade(Config.websocket_scheme(config), conn, target_path, headers) do
        {:ok, conn, request_ref} ->
          await_upgrade(conn, request_ref, config, client)

        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, reason}
      end
    end
  end

  defp await_upgrade(conn, request_ref, config, client) do
    deadline =
      System.monotonic_time(:millisecond) + config.websocket_backend_upgrade_timeout

    result =
      receive_upgrade(conn, request_ref, config, deadline, %{
        status: nil,
        headers: nil,
        body: [],
        body_bytes: 0,
        done?: false,
        deferred: []
      })

    finish_upgrade(result, request_ref, config, client)
  end

  defp receive_upgrade(conn, request_ref, config, deadline, %{done?: false} = response) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case reduce_responses(responses, request_ref, config, response) do
              {:ok, response} -> receive_upgrade(conn, request_ref, config, deadline, response)
              {:error, reason, response} -> {:error, conn, reason, response}
            end

          {:error, conn, reason, responses} ->
            response = reduce_error_responses(responses, request_ref, config, response)
            {:error, conn, reason, response}

          :unknown ->
            receive_upgrade(conn, request_ref, config, deadline, %{
              response
              | deferred: [message | response.deferred]
            })
        end
    after
      timeout -> {:error, conn, :backend_upgrade_timeout, response}
    end
  end

  defp receive_upgrade(conn, _request_ref, _config, _deadline, response) do
    {:ok, conn, response}
  end

  defp reduce_responses(responses, request_ref, config, response) do
    Enum.reduce_while(responses, {:ok, response}, fn
      {:status, ^request_ref, status}, {:ok, response} ->
        {:cont, {:ok, %{response | status: status}}}

      {:headers, ^request_ref, headers}, {:ok, response} ->
        {:cont, {:ok, %{response | headers: headers}}}

      {:data, ^request_ref, data}, {:ok, response} ->
        case append_body(response, data, config.max_response_body_size) do
          {:ok, response} -> {:cont, {:ok, response}}
          {:error, reason} -> {:halt, {:error, reason, response}}
        end

      {:done, ^request_ref}, {:ok, response} ->
        {:cont, {:ok, %{response | done?: true}}}

      {:error, ^request_ref, reason}, {:ok, response} ->
        {:halt, {:error, reason, response}}

      _other, result ->
        {:cont, result}
    end)
  end

  defp reduce_error_responses(responses, request_ref, config, response) do
    case reduce_responses(responses, request_ref, config, response) do
      {:ok, response} -> response
      {:error, _reason, response} -> response
    end
  end

  defp append_body(response, data, :infinity) do
    {:ok,
     %{
       response
       | body: [data | response.body],
         body_bytes: response.body_bytes + byte_size(data)
     }}
  end

  defp append_body(response, data, max_bytes) do
    if response.body_bytes + byte_size(data) <= max_bytes do
      append_body(response, data, :infinity)
    else
      {:error, :backend_response_too_large}
    end
  end

  defp finish_upgrade({:ok, conn, response}, request_ref, config, client) do
    restore_deferred(response.deferred)

    case response.status do
      101 ->
        finish_switching_protocols(conn, request_ref, response, config, client)

      status when is_integer(status) ->
        headers = client_response_headers(response.headers || [], config)
        body = response.body |> Enum.reverse() |> IO.iodata_to_binary()
        Mint.HTTP.close(conn)
        {:reject, status, headers, body}

      _missing ->
        Mint.HTTP.close(conn)
        {:error, :invalid_backend_upgrade_response}
    end
  end

  defp finish_upgrade({:error, conn, reason, response}, _request_ref, _config, _client) do
    restore_deferred(response.deferred)
    Mint.HTTP.close(conn)
    {:error, reason}
  end

  defp finish_switching_protocols(conn, request_ref, response, config, client) do
    headers = response.headers || []

    with {:ok, response_headers} <- Headers.response_headers(headers, config),
         {:ok, response_headers} <- validate_subprotocol(client.headers, response_headers),
         {:ok, conn, websocket} <-
           Mint.WebSocket.new(conn, request_ref, response.status, headers) do
      state = %WebSocketProxy{
        config: config,
        conn: conn,
        websocket: websocket,
        request_ref: request_ref,
        client: client
      }

      {:ok, state, client_response_headers(response_headers)}
    else
      {:error, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp validate_subprotocol(client_headers, response_headers) do
    offered = header_tokens(client_headers, "sec-websocket-protocol")
    selected = header_tokens(response_headers, "sec-websocket-protocol")

    case selected do
      [] ->
        {:ok, response_headers}

      [protocol] ->
        if protocol in offered do
          {:ok, response_headers}
        else
          {:error, :backend_selected_unoffered_subprotocol}
        end

      _multiple ->
        {:error, :invalid_backend_subprotocol_response}
    end
  end

  defp client_response_headers(headers) do
    Enum.reject(headers, fn {name, _value} ->
      MapSet.member?(@client_managed_headers, String.downcase(name))
    end)
  end

  defp client_response_headers(headers, config) do
    case Headers.response_headers(headers, config) do
      {:ok, headers} -> client_response_headers(headers)
      {:error, _reason} -> []
    end
  end

  defp header_tokens(headers, name) do
    headers
    |> Enum.filter(fn {header_name, _value} -> String.downcase(header_name) == name end)
    |> Enum.flat_map(fn {_name, value} -> Plug.Conn.Utils.list(value) end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp target_path(config, path, query_string) do
    path = Config.build_target_path(config, path || "/")

    case query_string do
      query when is_binary(query) and query != "" -> path <> "?" <> query
      _empty -> path
    end
  end

  defp restore_deferred(messages) do
    messages
    |> Enum.reverse()
    |> Enum.each(&send(self(), &1))
  end
end
