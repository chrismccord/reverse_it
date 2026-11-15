defmodule ReverseIt.ConnectWatch do
  @moduledoc false

  # Tells a pooled request whether its error came from opening the upstream
  # connection. Finch reports a failed connect and a failed read with the same
  # error, but only a failed connect is safe to retry for every method: nothing
  # was sent. Finch emits `[:finch, :connect, :stop]` synchronously in the
  # requesting process, so the handler messages that process, and only while it
  # is inside a watched request (keyed by pid in a public ETS table).

  @table __MODULE__
  @event [:finch, :connect, :stop]

  def setup do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :telemetry.attach({__MODULE__, :connect}, @event, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(@event, _measurements, %{error: _error, name: name}, _config) do
    case :ets.lookup(@table, self()) do
      [{_pid, ^name, ref}] -> send(self(), {__MODULE__, ref})
      _ -> :ok
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Runs `fun` as a watched request against Finch pool `name`. Returns
  `{result, connect_failed?}`.
  """
  def run(name, fun) do
    ref = make_ref()
    :ets.insert(@table, {self(), name, ref})

    try do
      result = fun.()

      connect_failed? =
        receive do
          {__MODULE__, ^ref} -> true
        after
          0 -> false
        end

      {result, connect_failed?}
    after
      :ets.delete(@table, self())
    end
  end
end
