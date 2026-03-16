defmodule ReqCassette.ReqOptionsTest do
  use ExUnit.Case, async: false

  import ReqCassette

  alias Plug.Conn

  @cassette_dir "test/fixtures/req_options"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "req_options forwarding" do
    @tag capture_log: true
    test "forwards receive_timeout to the outbound request during recording" do
      # Use a raw TCP server instead of Bypass to avoid exit signal issues.
      # This server accepts a connection, waits 200ms, then sends a response.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Spawn a process to accept and handle the connection
      server_pid =
        spawn_link(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, 5000)
          # Read the HTTP request
          {:ok, _data} = :gen_tcp.recv(sock, 0, 5000)
          # Delay response
          Process.sleep(200)

          response =
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 15\r\n\r\n{\"status\":\"ok\"}"

          :gen_tcp.send(sock, response)
          :gen_tcp.close(sock)
          :gen_tcp.close(listen)
        end)

      # With a very short receive_timeout, the forwarded request should timeout.
      # ReqCassette wraps transport errors in RuntimeError via normalize_response/1.
      assert_raise RuntimeError, ~r/timeout/, fn ->
        with_cassette(
          "slow_timeout",
          [
            cassette_dir: @cassette_dir,
            req_options: [receive_timeout: 1, retry: false]
          ],
          fn plug ->
            Req.get!("http://localhost:#{port}/slow",
              plug: plug,
              retry: false
            )
          end
        )
      end

      Process.unlink(server_pid)
      Process.exit(server_pid, :kill)
    end

    test "forwards receive_timeout allowing slow requests to succeed" do
      bypass = Bypass.open()

      # Server responds after 100ms delay
      Bypass.expect_once(bypass, "GET", "/slow", fn conn ->
        Process.sleep(100)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: "ok"}))
      end)

      # With a generous receive_timeout, the request should succeed
      result =
        with_cassette(
          "slow_success",
          [cassette_dir: @cassette_dir, req_options: [receive_timeout: 30_000]],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/slow",
              plug: plug,
              retry: false
            )
          end
        )

      assert result.status == 200
      assert result.body["status"] == "ok"
    end

    test "forwards pool_timeout to the outbound request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      # pool_timeout should be accepted and forwarded without error
      result =
        with_cassette(
          "pool_timeout",
          [cassette_dir: @cassette_dir, req_options: [pool_timeout: 10_000]],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/api",
              plug: plug,
              retry: false
            )
          end
        )

      assert result.status == 200
    end

    test "defaults work when req_options not provided (backward compatible)" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      # No req_options - should work exactly as before
      result =
        with_cassette(
          "no_req_options",
          [cassette_dir: @cassette_dir],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/api",
              plug: plug,
              retry: false
            )
          end
        )

      assert result.status == 200
    end

    test "does not forward dangerous options like plug or adapter" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      # Even if user passes :plug or :adapter in req_options, they should be stripped
      # to prevent infinite recursion
      result =
        with_cassette(
          "no_plug_forward",
          [
            cassette_dir: @cassette_dir,
            req_options: [
              receive_timeout: 30_000,
              plug: {SomePlug, %{}},
              adapter: fn _ -> nil end
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/api",
              plug: plug,
              retry: false
            )
          end
        )

      assert result.status == 200
    end

    @tag capture_log: true
    test "bypass mode also forwards req_options" do
      # Use a raw TCP server instead of Bypass to avoid exit signal issues.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      server_pid =
        spawn_link(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, 5000)
          {:ok, _data} = :gen_tcp.recv(sock, 0, 5000)
          Process.sleep(200)

          response =
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 15\r\n\r\n{\"status\":\"ok\"}"

          :gen_tcp.send(sock, response)
          :gen_tcp.close(sock)
          :gen_tcp.close(listen)
        end)

      # With a very short receive_timeout in bypass mode, should also timeout
      assert_raise RuntimeError, ~r/timeout/, fn ->
        with_cassette(
          "bypass_timeout",
          [
            cassette_dir: @cassette_dir,
            mode: :bypass,
            req_options: [receive_timeout: 1, retry: false]
          ],
          fn plug ->
            Req.get!("http://localhost:#{port}/slow",
              plug: plug,
              retry: false
            )
          end
        )
      end

      Process.unlink(server_pid)
      Process.exit(server_pid, :kill)
    end
  end
end
