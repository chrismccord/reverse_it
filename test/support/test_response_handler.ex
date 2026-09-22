defmodule ReverseIt.TestResponseHandler do
  @behaviour ReverseIt.ResponseHandler

  @impl true
  def handle_headers(status, headers, state) do
    send(state.owner, {:headers, status, headers})

    result =
      case state.mode do
        {:buffer, limit} -> {:buffer, limit, state}
        :bad_headers -> {:stream, [{"x-bad", "value\r\ninjected: true"}], state}
        :reject -> {:error, :unsupported_encoding, state}
        _ -> {:stream, [{"x-processed", "yes"} | headers], state}
      end

    case {result, Map.get(state, :commit)} do
      {{:stream, headers, state}, :headers} -> {:stream, headers, state, commit: :headers}
      _ -> result
    end
  end

  @impl true
  def handle_data(data, state) do
    send(state.owner, {:data, data})
    state = Map.update(state, :bytes, byte_size(data), &(&1 + byte_size(data)))

    case state.mode do
      :frames ->
        parts = String.split(Map.get(state, :pending, "") <> data, "\n")
        {frames, [pending]} = Enum.split(parts, -1)
        output = Enum.map(frames, &(String.replace(&1, "secret", "REDACTED") <> "\n"))
        {:ok, output, Map.put(state, :pending, pending)}

      :expand ->
        {:ok, [data, data], state}

      :reject_data ->
        {:error, :bad_data, state}

      :raise ->
        raise "handler bug"

      _ ->
        {:ok, data, state}
    end
  end

  @impl true
  def handle_end(%{mode: :frames, pending: pending} = state) when pending != "",
    do: {:error, :incomplete_frame, state}

  def handle_end(%{mode: :suffix} = state), do: {:ok, "!", state}
  def handle_end(state), do: {:ok, "", state}

  @impl true
  def terminate(outcome, state), do: send(state.owner, {:terminated, outcome, state})
end
