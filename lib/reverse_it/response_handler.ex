defmodule ReverseIt.ResponseHandler do
  @moduledoc """
  Application-owned HTTP response processing for `ReverseIt.request/2`.

  Configure `response_handler: {MyHandler, initial_state}`. Callbacks run
  synchronously in the requesting process. Use HTTP/1 upstreams for Finch's
  synchronous downstream backpressure.
  State is returned with the request result; no process dictionary is used.

  `handle_headers/3` sees validated, hop-by-hop filtered headers before any
  downstream response is committed. Choose `{:stream, headers, state}` or
  `{:buffer, finite_byte_limit, state}`. Buffering returns the complete response
  to the caller without sending it. The configured response limit also applies.

  Streaming invokes `handle_data/2` for each transport chunk and `handle_end/1`
  once on upstream completion. Return `{:ok, iodata, state}` to emit bytes
  (including empty bytes), or `{:error, reason, state}` to abort. Chunk boundaries
  are arbitrary; applications must bound any retained framing state themselves.
  Handled streams drop Content-Length because callbacks may change their length.

  `terminate/2` observes `:ok`, `:buffered`, or `{:error, reason}` after transport
  processing, including downstream cancellation. It must not raise. Before
  commitment an error is returned; after commitment the request process exits
  so the server truncates/resets the response instead of falsely completing it.
  Callback exceptions propagate as programming errors, not transport results.

  Buffer mode does not invoke data/end callbacks; inspect or rewrite its returned
  body in the caller. Retries are caller-owned and only possible before commitment
  with a replayable request body. Configuring a handler disables automatic
  `response_header_retries`; the caller owns every attempt. No provider-specific
  retry policy is built in.
  """

  @type headers :: [{String.t(), String.t()}]
  @callback handle_headers(pos_integer(), headers(), term()) ::
              {:stream, headers(), term()}
              | {:buffer, non_neg_integer(), term()}
              | {:error, term(), term()}
  @callback handle_data(binary(), term()) :: {:ok, iodata(), term()} | {:error, term(), term()}
  @callback handle_end(term()) :: {:ok, iodata(), term()} | {:error, term(), term()}
  @callback terminate(:ok | :buffered | {:error, term()}, term()) :: any()
  @optional_callbacks handle_data: 2, handle_end: 1, terminate: 2
end
