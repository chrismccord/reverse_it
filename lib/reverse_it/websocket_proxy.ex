defmodule ReverseIt.WebSocketProxy do
  @moduledoc """
  WebSocket proxy handler implementing the WebSock behavior.
  Maintains bidirectional connection between client and backend.
  """

  require Logger
  alias ReverseIt.{Config, Headers, Upstream}

  @behaviour WebSock

  defstruct [
    :config,
    :conn,
    :websocket,
    :request_ref,
    :client,
    :backend_upgrade_timer,
    pending_frames: [],
    pending_bytes: 0
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          conn: Mint.HTTP.t(),
          websocket: Mint.WebSocket.t(),
          request_ref: Mint.Types.request_ref(),
          client: map(),
          backend_upgrade_timer: reference() | nil,
          pending_frames: [Mint.WebSocket.frame()],
          pending_bytes: non_neg_integer()
        }

  @doc """
  Initializes the WebSocket proxy connection.

  The state contains:
  - config: Backend configuration
  - client_headers: Original client headers for forwarding
  """
  @impl WebSock
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    client = Keyword.fetch!(opts, :client)

    # Connect to backend
    case Upstream.connect(config) do
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
        headers = Headers.websocket_request_headers(client, config)

        # Upgrade to WebSocket
        case Mint.WebSocket.upgrade(Config.websocket_scheme(config), conn, target_path, headers) do
          {:ok, conn, request_ref} ->
            timer =
              Process.send_after(
                self(),
                :reverse_it_backend_websocket_upgrade_timeout,
                config.websocket_backend_upgrade_timeout
              )

            # Return immediately with partial state
            # The upgrade response will be handled in handle_info/2
            state = %__MODULE__{
              config: config,
              conn: conn,
              websocket: nil,
              request_ref: request_ref,
              client: client,
              backend_upgrade_timer: timer
            }

            Logger.debug("WebSocket upgrade initiated, waiting for backend response")
            {:ok, state}

          {:error, reason} ->
            Logger.error("Failed to initiate WebSocket upgrade: #{inspect(reason)}")
            {:stop, :normal, %__MODULE__{config: config, conn: conn}}
        end

      {:error, reason} ->
        Logger.error("Failed to connect to backend: #{inspect(reason)}")
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

    cond do
      byte_size(data) > state.config.max_websocket_frame_size ->
        {:stop, :message_too_large, {1009, "message too large"}, state}

      state.websocket == nil ->
        buffer_pending_frame(frame, data, state)

      true ->
        send_frame_to_backend(frame, state)
    end
  end

  @doc """
  Handles control frames from the client.
  """
  @impl WebSock
  def handle_control({data, opcode: :ping}, state) do
    # If WebSocket isn't ready yet, ignore ping
    if state.websocket == nil do
      {:ok, state}
    else
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
  end

  def handle_control({data, opcode: :pong}, state) do
    # If WebSocket isn't ready yet, ignore pong
    if state.websocket == nil do
      {:ok, state}
    else
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
  end

  def handle_control({_data, opcode: :close}, state) do
    # Client wants to close, forward to backend if ready
    if state.websocket == nil do
      {:stop, :normal, state}
    else
      case Mint.WebSocket.encode(state.websocket, :close) do
        {:ok, websocket, data} ->
          Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data)
          {:stop, :normal, %{state | websocket: websocket}}

        {:error, _websocket, _reason} ->
          {:stop, :normal, state}
      end
    end
  end

  @doc """
  Handles messages from the backend connection.
  """
  @impl WebSock
  def handle_info(:reverse_it_backend_websocket_upgrade_timeout, %{websocket: nil} = state) do
    Logger.error("Backend WebSocket upgrade timed out")
    {:stop, :backend_upgrade_timeout, {1011, "backend upgrade timeout"}, state}
  end

  def handle_info(:reverse_it_backend_websocket_upgrade_timeout, state) do
    {:ok, state}
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}

        # If websocket is nil, we're still waiting for upgrade
        if state.websocket == nil do
          process_upgrade_responses(responses, state)
        else
          process_backend_responses(responses, state)
        end

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

  defp process_upgrade_responses(responses, state) do
    # Collect status and headers from responses
    process_upgrade_responses(responses, state, nil, nil)
  end

  defp process_upgrade_responses([], state, status, headers)
       when status != nil and headers != nil do
    # All responses collected, create WebSocket
    Logger.debug("Creating WebSocket with status=#{status}")

    case Mint.WebSocket.new(state.conn, state.request_ref, status, headers) do
      {:ok, conn, websocket} ->
        Logger.debug("WebSocket connection established to backend")
        cancel_backend_upgrade_timer(state)
        state = %{state | conn: conn, websocket: websocket, backend_upgrade_timer: nil}
        # Flush any pending frames that arrived before upgrade completed
        flush_pending_frames(state)

      {:error, conn, reason} ->
        Logger.error("Failed to create WebSocket: #{inspect(reason)}")
        {:stop, :normal, %{state | conn: conn}}
    end
  end

  defp process_upgrade_responses([], state, _status, _headers) do
    # Didn't get complete upgrade response yet, wait for more messages
    {:ok, state}
  end

  defp process_upgrade_responses([response | rest], state, status, headers) do
    case response do
      {:status, ref, new_status} when ref == state.request_ref ->
        if new_status == 101 do
          Logger.debug("WebSocket upgrade successful (101)")
          process_upgrade_responses(rest, state, new_status, headers)
        else
          Logger.error("WebSocket upgrade failed with status: #{new_status}")
          {:stop, :normal, state}
        end

      {:headers, ref, new_headers} when ref == state.request_ref ->
        Logger.debug("Received upgrade headers")
        process_upgrade_responses(rest, state, status, new_headers)

      {:done, ref} when ref == state.request_ref ->
        Logger.debug("Received :done for upgrade")
        # Continue processing with current status/headers
        process_upgrade_responses(rest, state, status, headers)

      {:error, ref, reason} when ref == state.request_ref ->
        Logger.error("WebSocket upgrade error: #{inspect(reason)}")
        {:stop, :normal, state}

      other ->
        Logger.debug("Ignoring upgrade response: #{inspect(other)}")
        process_upgrade_responses(rest, state, status, headers)
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

            if backend_websocket_size_ok?(frames, websocket, state.config) do
              forward_frames_to_client(frames, rest, state)
            else
              {:stop, :backend_message_too_large, {1009, "message too large"}, state}
            end

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
          {:ok, state} -> {:push, [{:text, data}], state}
          {:push, frames, state} -> {:push, [{:text, data} | frames], state}
          other -> other
        end

      {:binary, data} ->
        case forward_frames_to_client(rest, remaining_responses, state) do
          {:ok, state} -> {:push, [{:binary, data}], state}
          {:push, frames, state} -> {:push, [{:binary, data} | frames], state}
          other -> other
        end

      {:ping, data} ->
        case forward_frames_to_client(rest, remaining_responses, state) do
          {:ok, state} -> {:push, [{:ping, data}], state}
          {:push, frames, state} -> {:push, [{:ping, data} | frames], state}
          other -> other
        end

      {:pong, data} ->
        case forward_frames_to_client(rest, remaining_responses, state) do
          {:ok, state} -> {:push, [{:pong, data}], state}
          {:push, frames, state} -> {:push, [{:pong, data} | frames], state}
          other -> other
        end

      {:close, _code, _reason} ->
        {:stop, :normal, state}

      :close ->
        {:stop, :normal, state}
    end
  end

  defp send_frame_to_backend(frame, state) do
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

  defp flush_pending_frames(state) when state.pending_frames == [] do
    {:ok, state}
  end

  defp flush_pending_frames(state) do
    Logger.debug("Flushing #{length(state.pending_frames)} pending frames")
    flush_frames_recursive(state.pending_frames, %{state | pending_frames: [], pending_bytes: 0})
  end

  defp flush_frames_recursive([], state), do: {:ok, state}

  defp flush_frames_recursive([frame | rest], state) do
    case send_frame_to_backend(frame, state) do
      {:ok, state} -> flush_frames_recursive(rest, state)
      other -> other
    end
  end

  defp buffer_pending_frame(frame, data, state) do
    pending_frames = length(state.pending_frames) + 1
    pending_bytes = state.pending_bytes + byte_size(data)

    if pending_frames > state.config.max_websocket_pending_frames or
         pending_bytes > state.config.max_websocket_pending_bytes do
      {:stop, :pending_message_limit, {1009, "message too large"}, state}
    else
      Logger.debug("Buffering frame until WebSocket upgrade completes")

      {:ok,
       %{state | pending_frames: state.pending_frames ++ [frame], pending_bytes: pending_bytes}}
    end
  end

  defp cancel_backend_upgrade_timer(%{backend_upgrade_timer: nil}), do: :ok

  defp cancel_backend_upgrade_timer(%{backend_upgrade_timer: timer}) do
    Process.cancel_timer(timer)
    :ok
  end

  defp backend_websocket_size_ok?(frames, websocket, config) do
    Enum.all?(frames, fn
      {:text, data} -> byte_size(data) <= config.max_websocket_frame_size
      {:binary, data} -> byte_size(data) <= config.max_websocket_frame_size
      {:ping, data} -> byte_size(data) <= 125
      {:pong, data} -> byte_size(data) <= 125
      {:close, _code, reason} when is_binary(reason) -> byte_size(reason) <= 123
      {:close, _code, _reason} -> true
      :close -> true
      {:error, _reason} -> false
    end) and websocket_buffer_bytes(websocket) <= config.max_websocket_frame_size
  end

  defp websocket_buffer_bytes(%{buffer: buffer, fragment: fragment}) do
    byte_size(buffer) + websocket_fragment_bytes(fragment)
  end

  defp websocket_buffer_bytes(_websocket), do: 0

  defp websocket_fragment_bytes(nil), do: 0

  defp websocket_fragment_bytes(frame) when is_tuple(frame) and tuple_size(frame) >= 4 do
    case elem(frame, 3) do
      data when is_binary(data) -> byte_size(data)
      data when is_list(data) -> IO.iodata_length(data)
      _other -> 0
    end
  end

  defp websocket_fragment_bytes(_frame), do: 0
end
