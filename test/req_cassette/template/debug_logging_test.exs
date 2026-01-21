defmodule ReqCassette.Template.DebugLoggingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import ReqCassette

  alias Plug.Conn
  alias ReqCassette.Template.Debug

  @cassette_dir "test/fixtures/debug_logging"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "Debug.log_extraction/3" do
    test "logs when enabled" do
      variables = %{sku: ["1234-5678", "9999-0000"], order_id: ["ORD-123"]}
      patterns = %{sku: ~r/\d{4}-\d{4}/, order_id: ~r/ORD-\d+/}

      log =
        capture_log(fn ->
          Debug.log_extraction(variables, patterns, true)
        end)

      assert log =~ "[ReqCassette Template] Pattern Extraction"
      assert log =~ "sku"
      assert log =~ "order_id"
      assert log =~ "1234-5678"
      assert log =~ "9999-0000"
      assert log =~ "ORD-123"
    end

    test "does not log when disabled" do
      variables = %{sku: ["1234-5678"]}
      patterns = %{sku: ~r/\d{4}-\d{4}/}

      log =
        capture_log(fn ->
          Debug.log_extraction(variables, patterns, false)
        end)

      assert log == ""
    end

    test "handles empty variables" do
      log =
        capture_log(fn ->
          Debug.log_extraction(%{}, %{sku: ~r/\d+/}, true)
        end)

      assert log =~ "[ReqCassette Template] Pattern Extraction"
      assert log =~ "(none)"
    end
  end

  describe "Debug.log_match_attempt/5" do
    test "logs success when enabled" do
      cassette_req = %{"method" => "GET", "uri" => "https://example.com/{{sku.0}}"}
      incoming_req = %{"method" => "GET", "uri" => "https://example.com/{{sku.0}}"}
      variables = %{sku: ["1234-5678"]}

      log =
        capture_log(fn ->
          Debug.log_match_attempt(cassette_req, incoming_req, :match, variables, true)
        end)

      assert log =~ "[ReqCassette Template] Match SUCCESS"
      assert log =~ "sku.0"
      assert log =~ "1234-5678"
    end

    test "logs failure with diff when enabled" do
      cassette_req = %{"method" => "GET", "uri" => "https://example.com/{{sku.0}}"}
      incoming_req = %{"method" => "POST", "uri" => "https://example.com/{{sku.0}}"}
      diff = %{field: "method", expected: "GET", actual: "POST"}
      variables = %{sku: ["1234-5678"]}

      log =
        capture_log(fn ->
          Debug.log_match_attempt(
            cassette_req,
            incoming_req,
            {:error, diff},
            variables,
            true
          )
        end)

      assert log =~ "[ReqCassette Template] Match FAILED"
      assert log =~ "Template match failed"
      assert log =~ "method"
      assert log =~ "GET"
      assert log =~ "POST"
    end

    test "does not log when disabled" do
      log =
        capture_log(fn ->
          Debug.log_match_attempt(%{}, %{}, :match, %{}, false)
        end)

      assert log == ""
    end
  end

  describe "Debug.format_variables/1" do
    test "formats multiple variables with indices" do
      variables = %{sku: ["1234", "5678"], order_id: ["ORD-1"]}
      formatted = Debug.format_variables(variables)

      assert formatted =~ "sku.0 = \"1234\""
      assert formatted =~ "sku.1 = \"5678\""
      assert formatted =~ "order_id.0 = \"ORD-1\""
    end

    test "returns (none) for empty variables" do
      assert Debug.format_variables(%{}) == "  (none)"
    end
  end

  describe "Debug.format_request/1" do
    test "formats request with all fields" do
      request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/orders",
        "query_string" => "page=1&limit=10",
        "body_json" => %{"name" => "Test"}
      }

      formatted = Debug.format_request(request)

      assert formatted =~ "Method: POST"
      assert formatted =~ "URI: https://api.example.com/orders"
      assert formatted =~ "Query: page=1&limit=10"
      assert formatted =~ "Body (JSON)"
    end

    test "formats request without query or body" do
      request = %{
        "method" => "GET",
        "uri" => "https://api.example.com/health"
      }

      formatted = Debug.format_request(request)

      assert formatted =~ "Method: GET"
      assert formatted =~ "URI: https://api.example.com/health"
      refute formatted =~ "Query:"
      refute formatted =~ "Body"
    end
  end

  describe "integration: debug option in with_cassette" do
    @tag capture_log: true
    test "debug: true logs extraction during recording" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/products/1234-5678", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678", "name" => "Widget"}))
      end)

      log =
        capture_log(fn ->
          with_cassette(
            "debug_recording_test",
            [
              cassette_dir: @cassette_dir,
              template: [
                patterns: [sku: ~r/\d{4}-\d{4}/],
                debug: true
              ]
            ],
            fn plug ->
              Req.get!("http://localhost:#{bypass.port}/products/1234-5678", plug: plug)
            end
          )
        end)

      assert log =~ "[ReqCassette Template] Pattern Extraction"
      assert log =~ "1234-5678"
    end

    @tag capture_log: true
    test "debug: true logs match attempt during replay" do
      bypass = Bypass.open()

      # First, record a cassette with debug enabled
      Bypass.expect_once(bypass, "GET", "/products/1234-5678", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678", "name" => "Widget"}))
      end)

      with_cassette(
        "debug_replay_test",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/],
            debug: true
          ]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/products/1234-5678", plug: plug)
        end
      )

      # Now replay and capture log
      log =
        capture_log(fn ->
          with_cassette(
            "debug_replay_test",
            [
              cassette_dir: @cassette_dir,
              template: [
                patterns: [sku: ~r/\d{4}-\d{4}/],
                debug: true
              ]
            ],
            fn plug ->
              Req.get!("http://localhost:#{bypass.port}/products/9999-8888", plug: plug)
            end
          )
        end)

      assert log =~ "[ReqCassette Template] Match SUCCESS"
    end

    @tag capture_log: true
    test "debug: false produces no logs" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/products/1234-5678", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678"}))
      end)

      log =
        capture_log(fn ->
          with_cassette(
            "debug_disabled_test",
            [
              cassette_dir: @cassette_dir,
              template: [
                patterns: [sku: ~r/\d{4}-\d{4}/],
                debug: false
              ]
            ],
            fn plug ->
              Req.get!("http://localhost:#{bypass.port}/products/1234-5678", plug: plug)
            end
          )
        end)

      refute log =~ "[ReqCassette Template]"
    end

    @tag capture_log: true
    test "preset with debug: true works" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "msg_01XzW7o3s58J6KauMpLBFtEf",
            "type" => "message"
          })
        )
      end)

      log =
        capture_log(fn ->
          with_cassette(
            "preset_debug_test",
            [
              cassette_dir: @cassette_dir,
              template: [
                preset: :anthropic,
                debug: true
              ]
            ],
            fn plug ->
              Req.post!(
                "http://localhost:#{bypass.port}/v1/messages",
                json: %{"prompt" => "Hello"},
                plug: plug
              )
            end
          )
        end)

      assert log =~ "[ReqCassette Template] Pattern Extraction"
    end
  end
end
