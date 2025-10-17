defmodule ReverseIt.Config do
  @moduledoc """
  Configuration parser and validator for reverse proxy settings.
  """

  defstruct [
    :name,
    :scheme,
    :host,
    :port,
    :path_prefix,
    :strip_path,
    :timeout,
    :connect_timeout,
    :protocols,
    :verify_tls,
    :add_headers,
    :remove_headers,
    :max_body_size,
    :error_response
  ]

  @type t :: %__MODULE__{
          name: atom(),
          scheme: :http | :https | :ws | :wss,
          host: String.t(),
          port: non_neg_integer(),
          path_prefix: String.t() | nil,
          strip_path: String.t() | nil,
          timeout: non_neg_integer(),
          connect_timeout: non_neg_integer(),
          protocols: [:http1 | :http2],
          verify_tls: boolean(),
          add_headers: [{String.t(), String.t()}],
          remove_headers: [String.t()],
          max_body_size: non_neg_integer() | :infinity,
          error_response: {non_neg_integer(), String.t()}
        }

  @doc """
  Parses proxy configuration from options.

  ## Options

    * `:name` - Name of the Finch pool to use (required)
    * `:backend` - Backend URL (required). Can be http://, https://, ws://, or wss://
    * `:strip_path` - Path prefix to strip from incoming requests before proxying
    * `:timeout` - Request timeout in milliseconds (default: 30_000)
    * `:connect_timeout` - Connection timeout in milliseconds (default: 5_000)
    * `:protocols` - List of supported protocols (default: [:http1, :http2])
    * `:verify_tls` - Verify TLS certificates (default: true)
    * `:add_headers` - List of headers to add to backend requests (default: [])
    * `:remove_headers` - List of header names to remove from client requests (default: [])
    * `:max_body_size` - Maximum request/response body size in bytes (default: 10MB, :infinity for unlimited)
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
         {:ok, port} <- validate_port(uri.port, scheme) do
      case fetch_name(opts) do
        {:ok, name} ->
          config = %__MODULE__{
            name: name,
            scheme: scheme,
            host: host,
            port: port,
            path_prefix: normalize_path(uri.path),
            strip_path: normalize_path(opts[:strip_path]),
            timeout: opts[:timeout] || 30_000,
            connect_timeout: opts[:connect_timeout] || 5_000,
            protocols: opts[:protocols] || [:http1, :http2],
            verify_tls: Keyword.get(opts, :verify_tls, true),
            add_headers: opts[:add_headers] || [],
            remove_headers: opts[:remove_headers] || [],
            max_body_size: opts[:max_body_size] || 10_485_760,
            error_response: opts[:error_response] || {502, "Bad Gateway"}
          }

          {:ok, config}

        error ->
          error
      end
    end
  end

  @doc """
  Builds the target path for the backend request.
  """
  @spec build_target_path(t(), String.t()) :: String.t()
  def build_target_path(%__MODULE__{} = config, request_path) do
    # Strip the configured path if needed
    path =
      if config.strip_path do
        String.replace_prefix(request_path, config.strip_path, "")
      else
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

  # Private functions

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
  defp validate_port(port, _scheme) when is_integer(port), do: {:ok, port}

  defp normalize_path(nil), do: nil
  defp normalize_path(""), do: nil

  defp normalize_path(path) do
    path
    |> String.trim()
    |> String.trim_trailing("/")
  end
end
