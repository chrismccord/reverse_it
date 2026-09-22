defmodule ReverseIt.DisconnectedAdapter do
  @moduledoc false
  defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
  defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
  def chunk(_state, _data), do: {:error, :closed}
end
