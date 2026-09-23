defmodule ReverseIt.ResponseHandler do
  @moduledoc """
  Callbacks for inspecting, buffering, or transforming an HTTP response.

  Pass a handler and fresh state to `ReverseIt.request/3`:

      ReverseIt.request(conn, config,
        response_handler: {MyApp.ResponseHandler, initial_state}
      )

  Once upstream headers arrive, the header callback chooses whether to stream
  the response or buffer it with a finite limit. Buffered responses are returned
  unsent to the caller, which can inspect or replace them and decide whether the
  request is safe to retry.
  Streaming callbacks can observe bytes, transform them, or reject them.
  Failures during client validation, connection setup, or request-body reads
  can call `terminate/2` with the initial state before `handle_headers/3` runs.

  By default, handled streams send headers with the first nonempty output from
  a data or end callback. If no bytes are emitted, the response is sent only
  after the end callback succeeds. This is independent of response size limits.
  For quiet SSE or long-polling responses, the header callback can instead return
  `{:stream, headers, state, commit: :headers}` to send headers immediately.

  Before headers are sent, errors are returned to the caller. After headers are
  sent, errors exit the request process to abort the downstream response.

  Callbacks run synchronously in the requesting process. HTTP/1 upstreams provide
  synchronous downstream backpressure; HTTP/2 pools may queue incoming data.
  Configuring a handler disables automatic `response_header_retries`. Only retry
  unsent responses when the operation is safe to replay and the request body is
  still available, such as bytes passed in the `:request_body` option.
  """

  @type headers :: [{String.t(), String.t()}]

  @doc """
  Selects how to handle the final status and headers, before commitment.

  Called once per response, after header validation and hop-by-hop filtering.
  Informational responses and trailers do not invoke this callback.

  Return `{:stream, headers, state}` to stream with the supplied headers,
  `{:buffer, finite_byte_limit, state}` to return the response unsent, or
  `{:error, reason, state}` to reject it. Changed headers are validated again.
  Streaming responses discard Content-Length when a body is allowed, since the
  data callbacks may change the number of bytes emitted.

  Return `{:stream, headers, state, commit: :headers}` to send the status and
  validated headers immediately, even if no body bytes have arrived. This can
  avoid downstream header timeouts for quiet streams. Any later failure,
  including rejection of the first data chunk, aborts the response instead of
  returning an unsent error. Bodyless responses are sent immediately as well.
  An empty options list or `commit: :output` keeps the default deferred behavior,
  equivalent to returning `{:stream, headers, state}`.

  An invalid return shape or unknown commitment option produces
  `{:error, {:invalid_handler_return, :handle_headers}, conn, initial_state}`
  from `ReverseIt.request/3` and calls `terminate/2` with the state originally
  passed to this callback. Exceptions raised by the callback still propagate.

  The buffer limit and `max_response_body_size` both apply. The proxy does not
  decompress responses; reject unsupported encodings here if processing requires
  identity bytes.
  """
  @callback handle_headers(pos_integer(), headers(), term()) ::
              {:stream, headers(), term()}
              | {:stream, headers(), term(), [commit: :headers | :output]}
              | {:buffer, non_neg_integer(), term()}
              | {:error, term(), term()}

  @doc """
  Processes a transport chunk in stream mode.

  Return `{:ok, iodata, state}` to emit bytes, or `{:error, reason, state}` to
  stop. Empty output delays commitment unless `commit: :headers` was selected.
  Chunks need not contain complete JSON or SSE events, so applications must bound
  any framing state they retain.
  Both received and emitted bytes obey `max_response_body_size`.

  Optional; the default forwards bytes unchanged. Not called in buffer mode
  or for bodyless responses.
  """
  @callback handle_data(binary(), term()) :: {:ok, iodata(), term()} | {:error, term(), term()}

  @doc """
  Finishes stream processing after the upstream body completes successfully.

  Return `{:ok, iodata, state}` to flush final bytes, or `{:error, reason, state}`
  to report an incomplete frame or another processing failure.

  Optional; the default emits no additional bytes. Not called for upstream
  failures, buffer mode, or bodyless responses.
  """
  @callback handle_end(term()) :: {:ok, iodata(), term()} | {:error, term(), term()}

  @doc """
  Observes completion or failure with the final handler state.

  Outcomes are `:ok` for a completed stream, `:buffered` for a response returned
  unsent, and `{:error, reason}` for failure. Downstream write failures use
  `{:error, {:downstream, reason}}`. Errors before commitment are returned
  without logging; callers own their logging policy. Errors after commitment
  are logged once by the proxy before this callback runs and the process exits.
  This callback can run before `handle_headers/3`, including on client validation,
  connection, or request-body failures; in those cases it receives initial state.

  Optional. Keep this callback lightweight and do not raise. Callback exceptions
  propagate as programming errors; this notification is not guaranteed when a
  callback raises or the request process is terminated externally.
  """
  @callback terminate(:ok | :buffered | {:error, term()}, term()) :: any()

  @optional_callbacks handle_data: 2, handle_end: 1, terminate: 2
end
