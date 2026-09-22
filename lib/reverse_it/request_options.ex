defmodule ReverseIt.RequestOptions do
  @moduledoc false

  defstruct [:request_body, :response_handler]

  def parse!(opts) do
    with :ok <- validate_keys(opts),
         {:ok, body} <- validate_request_body(Keyword.get(opts, :request_body)),
         {:ok, handler} <- validate_response_handler(Keyword.get(opts, :response_handler)) do
      %__MODULE__{request_body: body, response_handler: handler}
    else
      {:error, reason} -> raise ArgumentError, "Invalid ReverseIt request options: #{reason}"
    end
  end

  defp validate_keys(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:request_body, :response_handler])) do
      :ok
    else
      {:error, "expected a keyword list containing only request_body and response_handler"}
    end
  end

  defp validate_request_body(body) when is_binary(body) or is_nil(body), do: {:ok, body}

  defp validate_request_body(_body), do: {:error, "request_body must be a binary or nil"}

  defp validate_response_handler(nil), do: {:ok, nil}

  # This check runs when a request is made, never during Plug.init/1. Handler
  # modules need not be compiled when a router's static config is initialized.
  defp validate_response_handler({module, _state} = handler) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :handle_headers, 3) do
      {:ok, handler}
    else
      {:error, "response_handler must be {module, state} implementing handle_headers/3"}
    end
  end

  defp validate_response_handler(_handler),
    do: {:error, "response_handler must be {module, state} implementing handle_headers/3"}
end
