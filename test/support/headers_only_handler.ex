defmodule ReverseIt.HeadersOnlyHandler do
  @moduledoc false
  @behaviour ReverseIt.ResponseHandler

  @impl true
  def handle_headers(_status, headers, state), do: {:stream, headers, state}
end
