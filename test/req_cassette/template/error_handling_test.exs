defmodule ReqCassette.Template.ErrorHandlingTest do
  use ExUnit.Case, async: true

  import ReqCassette

  alias Plug.Conn
  alias ReqCassette.Template.Debug

  @cassette_dir "test/fixtures/template_error_handling"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "Debug.format_diff/4 - error message formatting" do
    test "formats method mismatch error" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "https://api.example.com/sku/{{sku.0}}",
        "body" => ""
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/sku/{{sku.0}}",
        "body" => ""
      }

      diff = %{field: "method", expected: "GET", actual: "POST"}
      variables = %{sku: ["1234-5678"]}

      message = Debug.format_diff(cassette_request, incoming_request, diff, variables)

      # Verify message contains key information
      assert message =~ "Template match failed"
      assert message =~ "Method: GET"
      assert message =~ "Method: POST"
      assert message =~ "Field: method"
      assert message =~ "Expected: GET"
      assert message =~ "Actual:   POST"
      assert message =~ "sku.0 = \"1234-5678\""
      assert message =~ "HTTP method changed"
    end

    test "formats URI mismatch error" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "https://api.example.com/products/{{sku.0}}",
        "body" => ""
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "https://api.example.com/items/{{sku.0}}",
        "body" => ""
      }

      diff = %{
        field: "uri",
        expected: "https://api.example.com/products/{{sku.0}}",
        actual: "https://api.example.com/items/{{sku.0}}"
      }

      variables = %{sku: ["5555-6666"]}

      message = Debug.format_diff(cassette_request, incoming_request, diff, variables)

      assert message =~ "Template match failed"
      assert message =~ "Field: uri"
      assert message =~ "/products/"
      assert message =~ "/items/"
      assert message =~ "URI path changed"
    end

    test "formats body mismatch error" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/lookup",
        "body" => "Get SKU {{sku.0}}"
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/lookup",
        "body" => "Get product {{sku.0}}"
      }

      diff = %{
        field: "body",
        expected: "Get SKU {{sku.0}}",
        actual: "Get product {{sku.0}}"
      }

      variables = %{sku: ["1234-5678"]}

      message = Debug.format_diff(cassette_request, incoming_request, diff, variables)

      assert message =~ "Template match failed"
      assert message =~ "Field: body"
      assert message =~ "Get SKU"
      assert message =~ "Get product"
      assert message =~ "Request body structure changed"
    end

    test "formats JSON body mismatch error with pretty printing" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/api",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "name" => "Widget"
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/api",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "description" => "Widget"
        }
      }

      diff = %{
        field: "body",
        expected: Jason.encode!(cassette_request["body_json"]),
        actual: Jason.encode!(incoming_request["body_json"])
      }

      variables = %{sku: ["1234-5678"]}

      message = Debug.format_diff(cassette_request, incoming_request, diff, variables)

      assert message =~ "Template match failed"
      assert message =~ "Body (JSON):"
      # Should have formatted JSON
      assert message =~ ~s("sku")
    end

    test "formats error with multiple variables" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/compare",
        "body" => "Compare {{sku.0}} with {{sku.1}}"
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/compare",
        "body" => "Compare {{sku.0}} but exclude {{sku.1}}"
      }

      diff = %{
        field: "body",
        expected: "Compare {{sku.0}} with {{sku.1}}",
        actual: "Compare {{sku.0}} but exclude {{sku.1}}"
      }

      variables = %{sku: ["1111-2222", "3333-4444"]}

      message = Debug.format_diff(cassette_request, incoming_request, diff, variables)

      # Should list all variables
      assert message =~ "sku.0 = \"1111-2222\""
      assert message =~ "sku.1 = \"3333-4444\""
    end

    test "formats error with no variables" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "https://api.example.com/status"
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "https://api.example.com/status"
      }

      diff = %{field: "method", expected: "GET", actual: "POST"}
      variables = %{}

      message = Debug.format_diff(cassette_request, incoming_request, diff, variables)

      assert message =~ "Template match failed"
      assert message =~ "Extracted variables:"
      assert message =~ "(none)"
    end
  end

  describe "integration - template match failures" do
    @tag capture_log: true
    test "raises error when request structure changes" do
      bypass = Bypass.open()

      # Record with one structure
      Bypass.expect_once(bypass, "POST", "/lookup", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678"}))
      end)

      with_cassette(
        "structure_change",
        [
          cassette_dir: @cassette_dir,
          template: [patterns: [sku: ~r/\d{4}-\d{4}/]]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/lookup",
            body: "Get SKU 1234-5678",
            plug: plug
          )
        end
      )

      # Replay with DIFFERENT structure - should fail
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "structure_change",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            template: [patterns: [sku: ~r/\d{4}-\d{4}/]]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/lookup",
              body: "Get product 5555-6666",
              plug: plug
            )
          end
        )
      end
    end

    @tag capture_log: true
    test "raises error when method changes" do
      bypass = Bypass.open()

      # Record with GET
      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => "123"}))
      end)

      with_cassette(
        "method_change",
        [
          cassette_dir: @cassette_dir,
          template: [patterns: [id: ~r/\d+/]]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/data?id=123", plug: plug)
        end
      )

      # Replay with POST - should fail
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "method_change",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            template: [patterns: [id: ~r/\d+/]]
          ],
          fn plug ->
            Req.post!("http://localhost:#{bypass.port}/data?id=456", plug: plug)
          end
        )
      end
    end

    @tag capture_log: true
    test "raises error when URI path changes" do
      bypass = Bypass.open()

      # Record with /products
      Bypass.expect_once(bypass, "GET", "/products/1234", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => "1234"}))
      end)

      with_cassette(
        "path_change",
        [
          cassette_dir: @cassette_dir,
          template: [patterns: [id: ~r/\d+/]]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/products/1234", plug: plug)
        end
      )

      # Replay with /items - should fail
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "path_change",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            template: [patterns: [id: ~r/\d+/]]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/items/5678", plug: plug)
          end
        )
      end
    end

    @tag capture_log: true
    test "raises error when JSON structure changes" do
      bypass = Bypass.open()

      # Record with specific JSON structure
      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"result" => "ok"}))
      end)

      with_cassette(
        "json_structure_change",
        [
          cassette_dir: @cassette_dir,
          template: [patterns: [id: ~r/\d+/]]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/api",
            json: %{"id" => "123", "type" => "widget"},
            plug: plug
          )
        end
      )

      # Replay with different JSON structure - should fail
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "json_structure_change",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            template: [patterns: [id: ~r/\d+/]]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"id" => "456", "category" => "widget"},
              plug: plug
            )
          end
        )
      end
    end

    @tag capture_log: true
    test "provides helpful error message with cassette details" do
      # Don't create cassette at all
      error =
        assert_raise RuntimeError, fn ->
          with_cassette(
            "nonexistent",
            [
              cassette_dir: @cassette_dir,
              mode: :replay,
              template: [patterns: [id: ~r/\d+/]]
            ],
            fn plug ->
              Req.get!("http://example.com/test", plug: plug)
            end
          )
        end

      # Verify error message contains helpful information
      assert error.message =~ "Cassette not found"
      assert error.message =~ "nonexistent.json"
      assert error.message =~ "Mode is :replay"
    end
  end
end
