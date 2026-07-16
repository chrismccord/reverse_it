defmodule ReverseIt.TestUnixProxy do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(opts), do: ReverseIt.init(opts)

  @impl Plug
  def call(conn, opts), do: ReverseIt.call(conn, opts)
end
