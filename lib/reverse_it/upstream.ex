defmodule ReverseIt.Upstream do
  @moduledoc false

  alias ReverseIt.Config

  def connect(%Config{} = config, opts \\ []) do
    {address, port} =
      case config.unix_socket do
        path when is_binary(path) -> {{:local, path}, 0}
        nil -> {config.host, config.port}
      end

    Mint.HTTP.connect(Config.http_scheme(config), address, port,
      protocols: [:http1],
      mode: Keyword.get(opts, :mode, :active),
      hostname: config.host,
      transport_opts: Config.transport_opts(config)
    )
  end
end
