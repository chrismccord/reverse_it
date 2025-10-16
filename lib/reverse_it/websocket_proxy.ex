defmodule ReverseIt.WebSocketProxy do
  @moduledoc """
  WebSocket proxy handler implementing the WebSock behavior.
  Maintains bidirectional connection between client and backend.
  """

  require Logger
  alias ReverseIt.Config

  @behaviour WebSock

  defstruct [
    :config,
    :conn,
    :websocket,
    :request_ref,
    :client_headers
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          conn: Mint.HTTP.t(),
          websocket: Mint.WebSocket.t(),
          request_ref: Mint.Types.request_ref(),
          client_headers: [{String.t(), String.t()}]
        }

  # Hop-by-hop headers that should not be forwarded
  @hop_by_hop_headers [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "sec-websocket-accept",
    "sec-websocket-extensions",
    "sec-websocket-key",
    "sec-websocket-protocol",
    "sec-websocket-version"
  ]

  @doc """
  Initializes the WebSocket proxy connection.

  The state contains:
  - config: Backend configuration
  - client_headers: Original client headers for forwarding
  """
  @impl WebSock
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    client_headers = Keyword.get(opts, :client_headers, [])

    # Connect to backend
    scheme = Config.http_scheme(config)

    case Mint.HTTP.connect(scheme, config.host, config.port,
           protocols: [:http1],
           transport_opts: [timeout: config.timeout]
         ) do
      {:ok, conn} ->
        # Build target path
        target_path = Config.build_target_path(config, Keyword.get(opts, :path, "/"))

        # Add query string if present
        target_path =
          case Keyword.get(opts, :query_string) do
            nil -> target_path
            "" -> target_path
            qs -> target_path <> "?" <> qs
          end

        # Prepare headers for WebSocket upgrade
        headers = prepare_headers(client_headers, config)

        # Upgrade to WebSocket
        case Mint.WebSocket.upgrade(:ws, conn, target_path, headers) do
          {:ok, conn, request_ref} ->
            # Wait for upgrade response
            state = %__MODULE__{
              config: config,
              conn: conn,
              websocket: nil,
              request_ref: request_ref,
              client_headers: client_headers
            }

            # We need to receive the upgrade response
            case wait_for_upgrade(state) do
              {:ok, state} ->
                {:ok, state}

              {:error, reason} ->
                # Known limitation - async init needs refactoring
                Logger.debug("Failed to upgrade WebSocket connection: #{inspect(reason)}")
                {:stop, :normal, state}
            end

          {:error, reason} ->
            Logger.debug("Failed to initiate WebSocket upgrade: #{inspect(reason)}")
            {:stop, :normal, %__MODULE__{config: config, conn: conn}}
        end

      {:error, reason} ->
        Logger.debug("Failed to connect to backend: #{inspect(reason)}")
        {:stop, :normal, %__MODULE__{config: config}}
    end
  end

  @doc """
  Handles incoming frames from the client and forwards them to the backend.
  """
  @impl WebSock
  def handle_in({data, opcode: opcode}, state) do
    frame =
      case opcode do
        :text -> {:text, data}
        :binary -> {:binary, data}
        :ping -> {:ping, data}
        :pong -> {:pong, data}
      end

    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            Logger.error("Failed to send frame to backend: #{inspect(reason)}")
            {:stop, :normal, %{state | conn: conn}}
        end

      {:error, websocket, reason} ->
        Logger.error("Failed to encode frame: #{inspect(reason)}")
        {:stop, :normal, %{state | websocket: websocket}}
    end
  end

  @doc """
  Handles control frames from the client.
  """
  @impl WebSock
  def handle_control({data, opcode: :ping}, state) do
    # Forward ping to backend
    case Mint.WebSocket.encode(state.websocket, {:ping, data}) do
      {:ok, websocket, encoded_data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, encoded_data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            Logger.error("Failed to send ping to backend: #{inspect(reason)}")
            {:stop, :normal, %{state | conn: conn}}
        end

      {:error, websocket, reason} ->
        Logger.error("Failed to encode ping: #{inspect(reason)}")
        {:stop, :normal, %{state | websocket: websocket}}
    end
  end

  def handle_control({data, opcode: :pong}, state) do
    # Forward pong to backend
    case Mint.WebSocket.encode(state.websocket, {:pong, data}) do
      {:ok, websocket, encoded_data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, encoded_data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            Logger.error("Failed to send pong to backend: #{inspect(reason)}")
            {:stop, :normal, %{state | conn: conn}}
        end

      {:error, websocket, reason} ->
        Logger.error("Failed to encode pong: #{inspect(reason)}")
        {:stop, :normal, %{state | websocket: websocket}}
    end
  end

  def handle_control({_data, opcode: :close}, state) do
    # Client wants to close, forward to backend
    case Mint.WebSocket.encode(state.websocket, :close) do
      {:ok, websocket, data} ->
        Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data)
        {:stop, :normal, %{state | websocket: websocket}}

      {:error, _websocket, _reason} ->
        {:stop, :normal, state}
    end
  end

  @doc """
  Handles messages from the backend connection.
  """
  @impl WebSock
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        process_backend_responses(responses, state)

      {:error, conn, reason, _responses} ->
        Logger.error("Error streaming from backend: #{inspect(reason)}")
        {:stop, :normal, %{state | conn: conn}}

      :unknown ->
        # Not a Mint message
        {:ok, state}
    end
  end

  @doc """
  Cleanup when connection terminates.
  """
  @impl WebSock
  def terminate(reason, state) do
    Logger.debug("WebSocket proxy terminating: #{inspect(reason)}")

    if state.conn do
      Mint.HTTP.close(state.conn)
    end

    :ok
  end

  # Private functions

  defp wait_for_upgrade(state) do
    receive do
      message ->
        case Mint.WebSocket.stream(state.conn, message) do
          {:ok, conn, responses} ->
            case process_upgrade_response(responses, %{state | conn: conn}) do
              {:ok, state} -> {:ok, state}
              {:continue, state} -> wait_for_upgrade(state)
              {:error, reason} -> {:error, reason}
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            wait_for_upgrade(state)
        end
    after
      state.config.timeout ->
        {:error, :timeout}
    end
  end

  defp process_upgrade_response([], state), do: {:continue, state}

  defp process_upgrade_response([response | rest], state) do
    case response do
      {:status, ref, status} when ref == state.request_ref ->
        if status == 101 do
          process_upgrade_response(rest, state)
        else
          {:error, {:unexpected_status, status}}
        end

      {:headers, ref, _headers} when ref == state.request_ref ->
        process_upgrade_response(rest, state)

      {:done, ref} when ref == state.request_ref ->
        # Upgrade complete, create WebSocket
        case Mint.WebSocket.new(state.conn, state.request_ref, :client, []) do
          {:ok, conn, websocket} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, _conn, reason} ->
            {:error, reason}
        end

      {:error, ref, reason} when ref == state.request_ref ->
        {:error, reason}

      _other ->
        process_upgrade_response(rest, state)
    end
  end

  defp process_backend_responses([], state), do: {:ok, state}

  defp process_backend_responses([response | rest], state) do
    case response do
      {:data, ref, data} when ref == state.request_ref ->
        # Decode WebSocket frames from backend
        case Mint.WebSocket.decode(state.websocket, data) do
          {:ok, websocket, frames} ->
            state = %{state | websocket: websocket}
            forward_frames_to_client(frames, rest, state)

          {:error, websocket, reason} ->
            Logger.error("Failed to decode backend frame: #{inspect(reason)}")
            {:stop, :normal, %{state | websocket: websocket}}
        end

      {:error, ref, reason} when ref == state.request_ref ->
        Logger.error("Backend connection error: #{inspect(reason)}")
        {:stop, :normal, state}

      {:done, ref} when ref == state.request_ref ->
        # Backend closed connection
        {:stop, :normal, state}

      _other ->
        process_backend_responses(rest, state)
    end
  end

  defp forward_frames_to_client([], remaining_responses, state) do
    process_backend_responses(remaining_responses, state)
  end

  defp forward_frames_to_client([frame | rest], remaining_responses, state) do
    case frame do
      {:text, data} ->
        case forward_frames_to_client(rest, remaining_responses, state) do
          {:ok, state} -> {:push, {[text: data], []}, state}
          {:push, {messages, control}, state} -> {:push, {[{:text, data} | messages], control}, state}
          other -> other
        end

      {:binary, data} ->
        case forward_frames_to_client(rest, remaining_responses, state) do
          {:ok, state} -> {:push, {[binary: data], []}, state}
          {:push, {messages, control}, state} -> {:push, {[{:binary, data} | messages], control}, state}
          other -> other
        end

      {:ping, data} ->
        case forward_frames_to_client(rest, remaining_responses, state) do
          {:ok, state} -> {:push, {[], [ping: data]}, state}
          {:push, {messages, control}, state} -> {:push, {messages, [{:ping, data} | control]}, state}
          other -> other
        end

      {:pong, data} ->
        case forward_frames_to_client(rest, remaining_responses, state) do
          {:ok, state} -> {:push, {[], [pong: data]}, state}
          {:push, {messages, control}, state} -> {:push, {messages, [{:pong, data} | control]}, state}
          other -> other
        end

      {:close, _code, _reason} ->
        {:stop, :normal, state}

      :close ->
        {:stop, :normal, state}
    end
  end

  defp prepare_headers(client_headers, config) do
    client_headers
    |> filter_hop_by_hop_headers()
    |> replace_host_header(config)
    |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
  end

  defp filter_hop_by_hop_headers(headers) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(name) in @hop_by_hop_headers
    end)
  end

  defp replace_host_header(headers, config) do
    # Remove existing host header and add backend host
    headers = List.keydelete(headers, "host", 0)
    host = if config.port in [80, 443], do: config.host, else: "#{config.host}:#{config.port}"
    [{"host", host} | headers]
  end
end
