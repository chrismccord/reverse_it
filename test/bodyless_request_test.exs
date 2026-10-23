defmodule ReverseIt.BodylessRequestTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  for mode <- [:pooled, :one_shot] do
    @mode mode

    test "#{mode}: preserves absent, explicitly empty, and nonempty request bodies" do
      for method <- [:get, :head, :post, :put, :patch],
          {body, headers, options, expected_length} <- [
            {nil, [], [], if(method in [:get, :head], do: [], else: ["0"])},
            {"", [{"content-length", "0"}], [], ["0"]},
            {nil, [], [request_body: ""], ["0"]},
            {"payload", [], [], ["7"]}
          ] do
        conn = Plug.Test.conn(method, "/", body)
        conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
        request(conn, options, expected_length, body || "", @mode)
      end
    end

    test "#{mode}: an explicit absent body does not reread a consumed conn or retain stale framing" do
      conn = Plug.Test.conn(:get, "/", "consumed")
      {:ok, "consumed", conn} = read_body(conn)
      conn = put_req_header(conn, "content-length", "999")
      request(conn, [request_body: :none], [], "", @mode)
    end
  end

  defp request(conn, options, expected_length, expected_body, mode) do
    owner = self()

    pid =
      start_supervised!(
        {Bandit,
         plug: fn conn, _ ->
           {:ok, body, conn} = read_body(conn)
           send(owner, {:upstream, conn.req_headers, body})
           send_resp(conn, 200, "")
         end,
         port: 0},
        id: make_ref()
      )

    port = TestHelper.listener_port(pid)

    config =
      ReverseIt.init(
        name: ReverseIt.TestFinch,
        backend: "http://127.0.0.1:#{port}",
        upstream_connection: mode
      )

    assert {:ok, _, _} = ReverseIt.request(conn, config, options)
    assert_receive {:upstream, headers, body}
    assert for({"content-length", v} <- headers, do: v) == expected_length
    assert for({"transfer-encoding", v} <- headers, do: v) == []
    assert body == expected_body
  end
end
