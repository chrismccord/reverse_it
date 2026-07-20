defmodule ReverseIt.Config do
  @moduledoc """
  Configuration parser and validator for reverse proxy settings.
  """

  @default_max_request_body_size 100 * 1024 * 1024
  @default_request_body_buffer_size 1 * 1024 * 1024
  @default_request_body_chunk_size 64 * 1024
  @default_max_response_header_bytes 64 * 1024
  @default_max_request_header_bytes 64 * 1024
  @default_max_websocket_frame_size 16 * 1024 * 1024

  defstruct [
    :name,
    :scheme,
    :host,
    :port,
    :unix_socket,
    :upstream_connection,
    :path_prefix,
    :strip_path,
    :connect_timeout,
    :pool_timeout,
    :response_header_timeout,
    :upstream_idle_timeout,
    :request_body_read_timeout,
    :protocols,
    :verify_tls,
    :add_headers,
    :remove_headers,
    :forwarded_headers,
    :preserve_host_header,
    :max_request_body_size,
    :request_body_buffer_size,
    :request_body_chunk_size,
    :max_response_body_size,
    :max_response_header_bytes,
    :max_request_target_bytes,
    :max_request_header_line_bytes,
    :max_request_header_bytes,
    :max_request_headers,
    :websocket_idle_timeout,
    :websocket_backend_upgrade_timeout,
    :max_websocket_frame_size,
    :max_websocket_pending_bytes,
    :max_websocket_pending_frames,
    :websocket_compress,
    :websocket_validate_utf8,
    :websocket_fullsweep_after,
    :websocket_max_heap_size,
    :error_response
  ]

  @type t :: %__MODULE__{
          name: atom(),
          scheme: :http | :https | :ws | :wss,
          host: String.t(),
          port: non_neg_integer(),
          unix_socket: String.t() | nil,
          upstream_connection: :pooled | :one_shot,
          path_prefix: String.t() | nil,
          strip_path: String.t() | nil,
          connect_timeout: non_neg_integer(),
          pool_timeout: non_neg_integer(),
          response_header_timeout: non_neg_integer(),
          upstream_idle_timeout: non_neg_integer(),
          request_body_read_timeout: non_neg_integer(),
          protocols: [:http1 | :http2],
          verify_tls: boolean(),
          add_headers: [{String.t(), String.t()}],
          remove_headers: MapSet.t(String.t()),
          forwarded_headers: :append | :replace | false,
          preserve_host_header: boolean(),
          max_request_body_size: non_neg_integer() | :infinity,
          request_body_buffer_size: pos_integer(),
          request_body_chunk_size: pos_integer(),
          max_response_body_size: non_neg_integer() | :infinity,
          max_response_header_bytes: pos_integer(),
          max_request_target_bytes: pos_integer(),
          max_request_header_line_bytes: pos_integer(),
          max_request_header_bytes: pos_integer(),
          max_request_headers: pos_integer(),
          websocket_idle_timeout: non_neg_integer(),
          websocket_backend_upgrade_timeout: non_neg_integer(),
          max_websocket_frame_size: pos_integer(),
          max_websocket_pending_bytes: non_neg_integer(),
          max_websocket_pending_frames: non_neg_integer(),
          websocket_compress: boolean(),
          websocket_validate_utf8: boolean(),
          websocket_fullsweep_after: non_neg_integer() | nil,
          websocket_max_heap_size: :erlang.max_heap_size() | nil,
          error_response: {non_neg_integer(), String.t()}
        }

  @doc """
  Parses proxy configuration from options.

  ## Options

    * `:name` - Name of the Finch pool to use (required)
    * `:backend` - Backend URL (required). Can be http://, https://, ws://, or wss://
    * `:unix_socket` - Connect to this Unix-domain socket instead of the backend host/port
    * `:upstream_connection` - `:pooled` or `:one_shot` (default: `:pooled`)
    * `:strip_path` - Path prefix to strip from incoming requests before proxying
    * `:connect_timeout` - Connection timeout in milliseconds (default: 5_000)
    * `:pool_timeout` - Finch pool checkout timeout in milliseconds (default: 5_000)
    * `:response_header_timeout` - Time to wait for backend response headers (default: 30_000)
    * `:upstream_idle_timeout` - Rolling idle timeout for backend data (default: 55_000)
    * `:request_body_read_timeout` - Rolling timeout while reading client request bodies (default: 55_000)
    * `:protocols` - List of supported upstream HTTP protocols (default: [:http1])
    * `:verify_tls` - Verify TLS certificates (default: true)
    * `:add_headers` - List of headers to add to backend requests (default: [])
    * `:remove_headers` - List of header names to remove from client requests (default: [])
    * `:forwarded_headers` - `:append`, `:replace`, or `false` for X-Forwarded-* behavior (default: :append)
    * `:preserve_host_header` - Preserve the original Host header instead of the backend host (default: false)
    * `:max_request_body_size` - Maximum request body size in bytes (default: 100MB, :infinity for unlimited)
    * `:request_body_buffer_size` - Body size buffered before switching to request streaming (default: 1MB)
    * `:max_response_body_size` - Maximum response body size in bytes (default: :infinity)
    * `:max_response_header_bytes` - Maximum backend response header bytes (default: 64KB)
    * `:max_request_target_bytes` - Maximum request path/query bytes (default: 8KB)
    * `:max_request_header_line_bytes` - Maximum single request header bytes (default: 8KB)
    * `:max_request_header_bytes` - Maximum total request header bytes (default: 64KB)
    * `:max_request_headers` - Maximum number of request headers (default: 100)
    * `:websocket_idle_timeout` - WebSocket client idle timeout (default: 55_000)
    * `:websocket_backend_upgrade_timeout` - Backend WebSocket upgrade timeout (default: 5_000)
    * `:max_websocket_frame_size` - Maximum client/backend WebSocket message size (default: 16MB)
    * `:max_websocket_pending_bytes` - Maximum frames buffered before backend upgrade (default: 1MB)
    * `:max_websocket_pending_frames` - Maximum frame count buffered before backend upgrade (default: 16)
    * `:websocket_compress` - Negotiate client WebSocket compression (default: false)
    * `:error_response` - Response to return when backend fails (default: {502, "Bad Gateway"})

  ## Examples

      iex> ReverseIt.Config.parse(backend: "http://localhost:4000")
      {:ok, %ReverseIt.Config{scheme: :http, host: "localhost", port: 4000, ...}}

      iex> ReverseIt.Config.parse(backend: "https://api.example.com/v1", strip_path: "/api", verify_tls: false)
      {:ok, %ReverseIt.Config{...}}
  """
  @spec parse(keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(opts) do
    with {:ok, backend} <- fetch_backend(opts),
         {:ok, uri} <- parse_uri(backend),
         {:ok, scheme} <- validate_scheme(uri.scheme),
         {:ok, host} <- validate_host(uri.host),
         {:ok, port} <- validate_port(uri.port, scheme),
         {:ok, name} <- fetch_name(opts),
         {:ok, config} <- build_config(opts, name, scheme, host, port, uri),
         :ok <- validate_connection_config(config) do
      {:ok, config}
    end
  end

  @doc """
  Builds the target path for the backend request.
  """
  @spec build_target_path(t(), String.t()) :: String.t()
  def build_target_path(%__MODULE__{} = config, request_path) do
    # Strip the configured path if needed
    path =
      cond do
        is_nil(config.strip_path) ->
          request_path

        request_path == config.strip_path ->
          "/"

        String.starts_with?(request_path, config.strip_path <> "/") ->
          String.replace_prefix(request_path, config.strip_path, "")

        true ->
          request_path
      end

    # Add backend path prefix if configured
    path =
      if config.path_prefix do
        Path.join(config.path_prefix, path)
      else
        path
      end

    # Ensure path starts with /
    if String.starts_with?(path, "/") do
      path
    else
      "/" <> path
    end
  end

  @doc """
  Returns true if the scheme is for WebSocket connections.
  """
  @spec websocket?(t()) :: boolean()
  def websocket?(%__MODULE__{scheme: scheme}) when scheme in [:ws, :wss], do: true
  def websocket?(%__MODULE__{}), do: false

  @doc """
  Converts WebSocket scheme to HTTP scheme for Mint connection.
  """
  @spec http_scheme(t()) :: :http | :https
  def http_scheme(%__MODULE__{scheme: :ws}), do: :http
  def http_scheme(%__MODULE__{scheme: :wss}), do: :https
  def http_scheme(%__MODULE__{scheme: scheme}), do: scheme

  @doc """
  Returns the WebSocket scheme to use for a backend upgrade.
  """
  @spec websocket_scheme(t()) :: :ws | :wss
  def websocket_scheme(%__MODULE__{scheme: :wss}), do: :wss
  def websocket_scheme(%__MODULE__{}), do: :ws

  @doc """
  Returns transport options for direct Mint connections.
  """
  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = config) do
    opts =
      [timeout: config.connect_timeout]
      |> maybe_enable_ipv6(config.host)

    if config.scheme in [:https, :wss] and config.verify_tls == false do
      Keyword.put(opts, :verify, :verify_none)
    else
      opts
    end
  end

  defp maybe_enable_ipv6(opts, host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 8 -> Keyword.put(opts, :inet6, true)
      _other -> opts
    end
  end

  # Private functions

  defp build_config(opts, name, scheme, host, port, uri) do
    with {:ok, protocols} <- validate_protocols(Keyword.get(opts, :protocols, [:http1])),
         {:ok, add_headers} <- validate_add_headers(Keyword.get(opts, :add_headers, [])),
         {:ok, remove_headers} <- validate_remove_headers(Keyword.get(opts, :remove_headers, [])),
         {:ok, forwarded_headers} <-
           validate_forwarded_headers(Keyword.get(opts, :forwarded_headers, :append)),
         {:ok, error_response} <-
           validate_error_response(Keyword.get(opts, :error_response, {502, "Bad Gateway"})),
         {:ok, config} <-
           validate_numeric_options(%__MODULE__{
             name: name,
             scheme: scheme,
             host: host,
             port: port,
             unix_socket: Keyword.get(opts, :unix_socket),
             upstream_connection: Keyword.get(opts, :upstream_connection, :pooled),
             path_prefix: normalize_path(uri.path),
             strip_path: normalize_path(opts[:strip_path]),
             connect_timeout: Keyword.get(opts, :connect_timeout, 5_000),
             pool_timeout: Keyword.get(opts, :pool_timeout, 5_000),
             response_header_timeout: Keyword.get(opts, :response_header_timeout, 30_000),
             upstream_idle_timeout: Keyword.get(opts, :upstream_idle_timeout, 55_000),
             request_body_read_timeout: Keyword.get(opts, :request_body_read_timeout, 55_000),
             protocols: protocols,
             verify_tls: Keyword.get(opts, :verify_tls, true),
             add_headers: add_headers,
             remove_headers: remove_headers,
             forwarded_headers: forwarded_headers,
             preserve_host_header: Keyword.get(opts, :preserve_host_header, false),
             max_request_body_size:
               Keyword.get(opts, :max_request_body_size, @default_max_request_body_size),
             request_body_buffer_size:
               Keyword.get(opts, :request_body_buffer_size, @default_request_body_buffer_size),
             request_body_chunk_size:
               Keyword.get(opts, :request_body_chunk_size, @default_request_body_chunk_size),
             max_response_body_size: Keyword.get(opts, :max_response_body_size, :infinity),
             max_response_header_bytes:
               Keyword.get(opts, :max_response_header_bytes, @default_max_response_header_bytes),
             max_request_target_bytes: Keyword.get(opts, :max_request_target_bytes, 8_192),
             max_request_header_line_bytes:
               Keyword.get(opts, :max_request_header_line_bytes, 8_192),
             max_request_header_bytes:
               Keyword.get(opts, :max_request_header_bytes, @default_max_request_header_bytes),
             max_request_headers: Keyword.get(opts, :max_request_headers, 100),
             websocket_idle_timeout: Keyword.get(opts, :websocket_idle_timeout, 55_000),
             websocket_backend_upgrade_timeout:
               Keyword.get(opts, :websocket_backend_upgrade_timeout, 5_000),
             max_websocket_frame_size:
               Keyword.get(opts, :max_websocket_frame_size, @default_max_websocket_frame_size),
             max_websocket_pending_bytes:
               Keyword.get(opts, :max_websocket_pending_bytes, @default_request_body_buffer_size),
             max_websocket_pending_frames: Keyword.get(opts, :max_websocket_pending_frames, 16),
             websocket_compress: Keyword.get(opts, :websocket_compress, false),
             websocket_validate_utf8: Keyword.get(opts, :websocket_validate_utf8, true),
             websocket_fullsweep_after: Keyword.get(opts, :websocket_fullsweep_after),
             websocket_max_heap_size: Keyword.get(opts, :websocket_max_heap_size),
             error_response: error_response
           }) do
      {:ok, config}
    end
  end

  defp fetch_name(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_atom(name) -> {:ok, name}
      {:ok, _} -> {:error, "name must be an atom"}
      :error -> {:error, "name option is required"}
    end
  end

  defp fetch_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} when is_binary(backend) -> {:ok, backend}
      {:ok, _} -> {:error, "backend must be a string"}
      :error -> {:error, "backend option is required"}
    end
  end

  defp parse_uri(backend) do
    case URI.parse(backend) do
      %URI{scheme: nil} ->
        {:error, "backend must include a scheme (http://, https://, ws://, or wss://)"}

      uri ->
        {:ok, uri}
    end
  end

  defp validate_scheme(scheme) when scheme in ["http", "https", "ws", "wss"] do
    {:ok, String.to_existing_atom(scheme)}
  end

  defp validate_scheme(scheme) do
    {:error, "unsupported scheme: #{scheme}. Must be http, https, ws, or wss"}
  end

  defp validate_host(nil), do: {:error, "backend must include a host"}
  defp validate_host(host) when is_binary(host), do: {:ok, host}

  defp validate_port(nil, :http), do: {:ok, 80}
  defp validate_port(nil, :https), do: {:ok, 443}
  defp validate_port(nil, :ws), do: {:ok, 80}
  defp validate_port(nil, :wss), do: {:ok, 443}
  defp validate_port(port, _scheme) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp validate_port(_port, _scheme), do: {:error, "backend port must be between 1 and 65535"}

  defp validate_protocols(protocols) when is_list(protocols) and protocols != [] do
    if Enum.all?(protocols, &(&1 in [:http1, :http2])) do
      {:ok, protocols}
    else
      {:error, "protocols must be a non-empty list of :http1 or :http2"}
    end
  end

  defp validate_protocols(_protocols),
    do: {:error, "protocols must be a non-empty list of :http1 or :http2"}

  defp validate_add_headers(headers) when is_list(headers) do
    normalize_config_headers(headers)
  end

  defp validate_add_headers(_headers),
    do: {:error, "add_headers must be a list of {name, value} tuples"}

  defp validate_remove_headers(headers) when is_list(headers) do
    if Enum.all?(headers, &is_binary/1) do
      {:ok, headers |> Enum.map(&String.downcase/1) |> MapSet.new()}
    else
      {:error, "remove_headers must be a list of header names"}
    end
  end

  defp validate_remove_headers(_headers),
    do: {:error, "remove_headers must be a list of header names"}

  defp validate_forwarded_headers(value) when value in [:append, :replace, false],
    do: {:ok, value}

  defp validate_forwarded_headers(_value) do
    {:error, "forwarded_headers must be :append, :replace, or false"}
  end

  defp validate_error_response({status, body})
       when is_integer(status) and status in 400..599 and is_binary(body) do
    {:ok, {status, body}}
  end

  defp validate_error_response(_response) do
    {:error, "error_response must be a {status, body} tuple with a 4xx/5xx status"}
  end

  defp validate_connection_config(%__MODULE__{} = config) do
    cond do
      config.upstream_connection not in [:pooled, :one_shot] ->
        {:error, "upstream_connection must be :pooled or :one_shot"}

      not is_nil(config.unix_socket) and
          (not is_binary(config.unix_socket) or config.unix_socket == "") ->
        {:error, "unix_socket must be a non-empty string"}

      is_binary(config.unix_socket) and config.scheme not in [:http, :ws] ->
        {:error, "unix_socket supports only http and ws backends"}

      is_binary(config.unix_socket) and config.upstream_connection != :one_shot ->
        {:error, "unix_socket requires upstream_connection: :one_shot"}

      config.upstream_connection == :one_shot and config.protocols != [:http1] ->
        {:error, "one-shot upstream connections require protocols: [:http1]"}

      true ->
        :ok
    end
  end

  defp normalize_config_headers(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)

        if valid_header?(name, value) do
          {:cont, {:ok, [{name, value} | acc]}}
        else
          {:halt,
           {:error, "configured headers cannot contain colon, null, carriage return, or newline"}}
        end

      _other, {:ok, _acc} ->
        {:halt, {:error, "add_headers must be a list of {name, value} tuples"}}
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  defp validate_numeric_options(config) do
    checks = [
      {:connect_timeout, :non_negative_integer},
      {:pool_timeout, :non_negative_integer},
      {:response_header_timeout, :non_negative_integer},
      {:upstream_idle_timeout, :non_negative_integer},
      {:request_body_read_timeout, :non_negative_integer},
      {:max_request_body_size, :non_negative_integer_or_infinity},
      {:request_body_buffer_size, :positive_integer},
      {:request_body_chunk_size, :positive_integer},
      {:max_response_body_size, :non_negative_integer_or_infinity},
      {:max_response_header_bytes, :positive_integer},
      {:max_request_target_bytes, :positive_integer},
      {:max_request_header_line_bytes, :positive_integer},
      {:max_request_header_bytes, :positive_integer},
      {:max_request_headers, :positive_integer},
      {:websocket_idle_timeout, :non_negative_integer},
      {:websocket_backend_upgrade_timeout, :non_negative_integer},
      {:max_websocket_frame_size, :positive_integer},
      {:max_websocket_pending_bytes, :non_negative_integer},
      {:max_websocket_pending_frames, :non_negative_integer}
    ]

    Enum.reduce_while(checks, {:ok, config}, fn {field, type}, {:ok, config} ->
      value = Map.fetch!(config, field)

      if valid_number?(value, type) do
        {:cont, {:ok, config}}
      else
        {:halt, {:error, "#{field} must be #{describe_number_type(type)}"}}
      end
    end)
  end

  defp valid_number?(value, :positive_integer), do: is_integer(value) and value > 0
  defp valid_number?(value, :non_negative_integer), do: is_integer(value) and value >= 0
  defp valid_number?(:infinity, :non_negative_integer_or_infinity), do: true

  defp valid_number?(value, :non_negative_integer_or_infinity),
    do: valid_number?(value, :non_negative_integer)

  defp describe_number_type(:positive_integer), do: "a positive integer"
  defp describe_number_type(:non_negative_integer), do: "a non-negative integer"

  defp describe_number_type(:non_negative_integer_or_infinity),
    do: "a non-negative integer or :infinity"

  defp valid_header?(name, value) do
    :binary.match(name, [":", "\n", "\r", "\x00"]) == :nomatch and
      :binary.match(value, ["\n", "\r", "\x00"]) == :nomatch
  end

  defp normalize_path(nil), do: nil
  defp normalize_path(""), do: nil

  defp normalize_path(path) do
    path =
      path
      |> String.trim()
      |> String.trim_trailing("/")

    if path == "", do: nil, else: path
  end
end
