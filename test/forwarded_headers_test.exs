defmodule ReverseIt.ForwardedHeadersTest do
  use ExUnit.Case, async: true

  alias ReverseIt.Headers

  @spoofed for name <- ["x-forwarded-for", "x-forwarded-proto", "x-forwarded-host"],
               value <- ["first-spoof", "second-spoof"],
               do: {name, value}

  test "replace removes all duplicate HTTP forwarded headers" do
    conn = Plug.Test.conn("GET", "/")
    unrelated = [{"x-custom", "first"}, {"x-custom", "second"}]
    conn = %{conn | req_headers: [{"host", "public.example"} | @spoofed ++ unrelated]}
    headers = Headers.request_headers(conn, config(:replace))

    assert values(headers, "x-forwarded-for") == ["127.0.0.1"]
    assert values(headers, "x-forwarded-proto") == ["http"]
    assert values(headers, "x-forwarded-host") == ["public.example"]
    assert values(headers, "x-custom") == ["first", "second"]
  end

  test "WebSocket replacement removes spoofed host even without a client Host header" do
    client = %{headers: @spoofed, remote_ip: "192.0.2.1", scheme: "https", host: nil}
    headers = Headers.websocket_request_headers(client, config(:replace))

    assert values(headers, "x-forwarded-for") == ["192.0.2.1"]
    assert values(headers, "x-forwarded-proto") == ["https"]
    assert values(headers, "x-forwarded-host") == []
  end

  test "disabled forwarding leaves client headers unchanged" do
    conn = %{Plug.Test.conn("GET", "/") | req_headers: @spoofed}
    headers = Headers.request_headers(conn, config(false))
    assert Enum.all?(@spoofed, &(&1 in headers))
  end

  defp config(policy) do
    ReverseIt.init(name: UnusedFinch, backend: "http://backend", forwarded_headers: policy)
  end

  defp values(headers, name), do: for({^name, value} <- headers, do: value)
end
