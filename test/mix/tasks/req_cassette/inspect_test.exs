defmodule Mix.Tasks.ReqCassette.InspectTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import ReqCassette

  alias Mix.Tasks.ReqCassette.Inspect, as: InspectTask
  alias Plug.Conn

  @cassette_dir "test/fixtures/inspect_task"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "basic usage" do
    @tag capture_log: true
    test "displays cassette information" do
      # Create a cassette with templates
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/products/1234-5678", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678", "name" => "Widget"}))
      end)

      with_cassette(
        "inspect_test_basic",
        [
          cassette_dir: @cassette_dir,
          template: [patterns: [sku: ~r/\d{4}-\d{4}/]]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/products/1234-5678", plug: plug)
        end
      )

      cassette_path = Path.join(@cassette_dir, "inspect_test_basic.json")

      output =
        capture_io(fn ->
          InspectTask.run([cassette_path])
        end)

      assert output =~ "Cassette: #{cassette_path}"
      assert output =~ "Version: 2.0"
      assert output =~ "Interactions: 1"
      assert output =~ "Template: ENABLED"
      assert output =~ "sku"
      assert output =~ "1234-5678"
      assert output =~ "GET"
    end

    test "handles non-existent file" do
      output =
        capture_io(:stderr, fn ->
          InspectTask.run(["nonexistent.json"])
        end)

      assert output =~ "Error: nonexistent.json - File not found"
    end

    test "shows usage when no arguments" do
      output =
        capture_io(:stderr, fn ->
          catch_exit(InspectTask.run([]))
        end)

      assert output =~ "Usage: mix req_cassette.inspect"
    end
  end

  describe "multiple cassettes" do
    @tag capture_log: true
    test "processes multiple files" do
      bypass = Bypass.open()

      # Create first cassette
      Bypass.expect_once(bypass, "GET", "/first", fn conn ->
        Conn.resp(conn, 200, "first")
      end)

      with_cassette(
        "inspect_multi_1",
        [cassette_dir: @cassette_dir],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/first", plug: plug)
        end
      )

      # Create second cassette
      Bypass.expect_once(bypass, "GET", "/second", fn conn ->
        Conn.resp(conn, 200, "second")
      end)

      with_cassette(
        "inspect_multi_2",
        [cassette_dir: @cassette_dir],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/second", plug: plug)
        end
      )

      path1 = Path.join(@cassette_dir, "inspect_multi_1.json")
      path2 = Path.join(@cassette_dir, "inspect_multi_2.json")

      output =
        capture_io(fn ->
          InspectTask.run([path1, path2])
        end)

      assert output =~ "inspect_multi_1.json"
      assert output =~ "inspect_multi_2.json"
      assert output =~ "/first"
      assert output =~ "/second"
    end
  end

  describe "--verbose option" do
    @tag capture_log: true
    test "shows request and response bodies" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"result" => "success"}))
      end)

      with_cassette(
        "inspect_verbose",
        [cassette_dir: @cassette_dir],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/api",
            json: %{"query" => "test"},
            plug: plug
          )
        end
      )

      cassette_path = Path.join(@cassette_dir, "inspect_verbose.json")

      # Without verbose
      output_basic =
        capture_io(fn ->
          InspectTask.run([cassette_path])
        end)

      refute output_basic =~ "Request Body:"
      refute output_basic =~ "Response Body:"

      # With verbose
      output_verbose =
        capture_io(fn ->
          InspectTask.run(["--verbose", cassette_path])
        end)

      assert output_verbose =~ "Request Body:"
      assert output_verbose =~ "Response Body:"
      assert output_verbose =~ "query"
      assert output_verbose =~ "result"
    end

    @tag capture_log: true
    test "-v shorthand works" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Conn.resp(conn, 200, "test")
      end)

      with_cassette(
        "inspect_v_short",
        [cassette_dir: @cassette_dir],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/test", plug: plug)
        end
      )

      cassette_path = Path.join(@cassette_dir, "inspect_v_short.json")

      output =
        capture_io(fn ->
          InspectTask.run(["-v", cassette_path])
        end)

      assert output =~ "Request Body:"
    end
  end

  describe "--json option" do
    @tag capture_log: true
    test "outputs valid JSON" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => "123"}))
      end)

      with_cassette(
        "inspect_json",
        [
          cassette_dir: @cassette_dir,
          template: [patterns: [id: ~r/\d+/]]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/api/data", plug: plug)
        end
      )

      cassette_path = Path.join(@cassette_dir, "inspect_json.json")

      output =
        capture_io(fn ->
          InspectTask.run(["--json", cassette_path])
        end)

      # Should be valid JSON
      assert {:ok, parsed} = Jason.decode(output)

      assert parsed["path"] == cassette_path
      assert parsed["version"] == "2.0"
      assert parsed["interaction_count"] == 1

      [interaction] = parsed["interactions"]
      assert interaction["template_enabled"] == true
      assert "id" in interaction["patterns"]
    end

    @tag capture_log: true
    test "-j shorthand works" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Conn.resp(conn, 200, "ok")
      end)

      with_cassette(
        "inspect_j_short",
        [cassette_dir: @cassette_dir],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/test", plug: plug)
        end
      )

      cassette_path = Path.join(@cassette_dir, "inspect_j_short.json")

      output =
        capture_io(fn ->
          InspectTask.run(["-j", cassette_path])
        end)

      assert {:ok, _parsed} = Jason.decode(output)
    end

    @tag capture_log: true
    test "JSON output with --verbose includes bodies" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"result" => "ok"}))
      end)

      with_cassette(
        "inspect_json_verbose",
        [cassette_dir: @cassette_dir],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/api",
            json: %{"query" => "test"},
            plug: plug
          )
        end
      )

      cassette_path = Path.join(@cassette_dir, "inspect_json_verbose.json")

      output =
        capture_io(fn ->
          InspectTask.run(["--json", "--verbose", cassette_path])
        end)

      {:ok, parsed} = Jason.decode(output)
      [interaction] = parsed["interactions"]

      assert interaction["request_body"]["query"] == "test"
      assert interaction["response_body"]["result"] == "ok"
    end
  end

  describe "non-templated cassettes" do
    @tag capture_log: true
    test "shows Template: DISABLED for non-templated cassettes" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/simple", fn conn ->
        Conn.resp(conn, 200, "ok")
      end)

      with_cassette(
        "inspect_no_template",
        [cassette_dir: @cassette_dir],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/simple", plug: plug)
        end
      )

      cassette_path = Path.join(@cassette_dir, "inspect_no_template.json")

      output =
        capture_io(fn ->
          InspectTask.run([cassette_path])
        end)

      assert output =~ "Template: DISABLED"
    end
  end

  describe "multiple interactions" do
    @tag capture_log: true
    test "shows all interactions with indices" do
      bypass = Bypass.open()

      # Record multiple interactions in same cassette
      Bypass.expect(bypass, "GET", "/users/1", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => 1}))
      end)

      Bypass.expect(bypass, "GET", "/users/2", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => 2}))
      end)

      with_cassette(
        "inspect_multi_interaction",
        [cassette_dir: @cassette_dir],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/users/1", plug: plug)
          Req.get!("http://localhost:#{bypass.port}/users/2", plug: plug)
        end
      )

      cassette_path = Path.join(@cassette_dir, "inspect_multi_interaction.json")

      output =
        capture_io(fn ->
          InspectTask.run([cassette_path])
        end)

      assert output =~ "Interactions: 2"
      assert output =~ "Interaction #1"
      assert output =~ "Interaction #2"
      assert output =~ "/users/1"
      assert output =~ "/users/2"
    end
  end
end
