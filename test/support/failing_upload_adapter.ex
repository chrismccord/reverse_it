defmodule ReverseIt.FailingUploadAdapter do
  @moduledoc false

  def read_req_body(%{upload_started?: true} = state, _opts) do
    send(state.test_owner, :upload_read_failed)
    {:error, :closed}
  end

  def read_req_body(state, opts) do
    {:more, data, state} = Plug.Adapters.Test.Conn.read_req_body(state, opts)
    {:more, data, Map.put(state, :upload_started?, true)}
  end

  defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
end
