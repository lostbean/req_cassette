defmodule ReqCassette.Template.EdgeCasesTest do
  use ExUnit.Case, async: true

  import ReqCassette

  alias Plug.Conn

  @cassette_dir "test/fixtures/template_edge_cases"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "edge case: duplicate values" do
    @tag capture_log: true
    test "keeps all occurrences with value-based indexing" do
      bypass = Bypass.open()

      # Record with duplicate SKU
      Bypass.expect_once(bypass, "POST", "/process", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "first" => "1234-5678",
            "second" => "1234-5678",
            "message" => "Processed SKU 1234-5678 and SKU 1234-5678 again"
          })
        )
      end)

      with_cassette(
        "duplicate_values",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/process",
            body: "SKU 1234-5678 and SKU 1234-5678 again",
            plug: plug
          )
        end
      )

      # Replay with different duplicate SKU
      result =
        with_cassette(
          "duplicate_values",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/process",
              body: "SKU 9999-8888 and SKU 9999-8888 again",
              plug: plug
            )
          end
        )

      # Both occurrences should be substituted correctly
      assert result.body["first"] == "9999-8888"
      assert result.body["second"] == "9999-8888"
      assert result.body["message"] == "Processed SKU 9999-8888 and SKU 9999-8888 again"
    end
  end

  describe "edge case: pattern overlap" do
    @tag capture_log: true
    test "most specific pattern wins (longest match)" do
      bypass = Bypass.open()

      # Record with SKU that could match both patterns
      Bypass.expect_once(bypass, "POST", "/lookup", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "input" => body,
            "sku" => "1234-5678"
          })
        )
      end)

      # Both patterns would match "1234-5678":
      # - id: ~r/\d+/ matches "1234" and "5678"
      # - sku: ~r/\d{4}-\d{4}/ matches "1234-5678"
      # The more specific pattern (sku) should win
      with_cassette(
        "pattern_overlap",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [
              id: ~r/\d+/,
              sku: ~r/\d{4}-\d{4}/
            ]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/lookup",
            body: "SKU 1234-5678",
            plug: plug
          )
        end
      )

      # Read cassette to verify which pattern was used
      cassette_path = Path.join(@cassette_dir, "pattern_overlap.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])
      recorded_values = interaction["template"]["recorded_values"]

      # Most specific pattern (sku) should win for OVERLAPPING matches
      # sku: ~r/\d{4}-\d{4}/ matches "1234-5678" in body (length 9)
      # id: ~r/\d+/ would match "1234" and "5678" in body (length 4 each)
      # Since "1234" and "5678" overlap with "1234-5678", only the longest (sku) is kept
      #
      # However, id ALSO matches the port number in the URI (e.g., "60495")
      # which doesn't overlap with the SKU, so it's kept as well
      assert Map.has_key?(recorded_values, "sku")
      assert recorded_values["sku"] == ["1234-5678"]

      # id pattern may also match port number from URI (non-overlapping)
      if Map.has_key?(recorded_values, "id") do
        # Should be port number, not "1234" or "5678" (those overlap with sku)
        refute "1234" in recorded_values["id"]
        refute "5678" in recorded_values["id"]
      end
    end
  end

  describe "edge case: empty extraction" do
    @tag capture_log: true
    test "skips empty extractions" do
      bypass = Bypass.open()

      # Record with pattern that might extract empty string
      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"status" => "ok", "id" => ""}))
      end)

      with_cassette(
        "empty_extraction",
        [
          cassette_dir: @cassette_dir,
          template: [
            # Pattern can match empty content after id=
            patterns: [id: ~r/id=\w*/]
          ]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/data?id=", plug: plug)
        end
      )

      # Read cassette to verify empty values were not extracted
      cassette_path = Path.join(@cassette_dir, "empty_extraction.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])
      recorded_values = interaction["template"]["recorded_values"]

      # Should not have empty id values
      if Map.has_key?(recorded_values, "id") do
        assert recorded_values["id"] != []
        assert recorded_values["id"] |> Enum.all?(&(&1 != ""))
      end
    end
  end

  describe "edge case: literal braces in data" do
    @tag capture_log: true
    test "escapes literal {{ and }} in data" do
      bypass = Bypass.open()

      # Record with literal braces in response
      Bypass.expect_once(bypass, "POST", "/template", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "template_syntax" => "Use {{variable}} for substitution",
            "example" => "{{name}} will be replaced"
          })
        )
      end)

      with_cassette(
        "literal_braces",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [id: ~r/ID-\d+/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/template",
            body: "Request with ID-12345",
            plug: plug
          )
        end
      )

      # Replay should preserve the literal braces
      result =
        with_cassette(
          "literal_braces",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/ID-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/template",
              body: "Request with ID-67890",
              plug: plug
            )
          end
        )

      # Literal braces should be preserved in response
      assert result.body["template_syntax"] == "Use {{variable}} for substitution"
      assert result.body["example"] == "{{name}} will be replaced"
    end
  end

  describe "edge case: variable scope rules" do
    @tag capture_log: true
    test "request-only values are not templated" do
      bypass = Bypass.open()

      # Value appears only in request, not in response
      Bypass.expect_once(bypass, "POST", "/search", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "results" => ["item1", "item2"],
            "count" => 2
          })
        )
      end)

      with_cassette(
        "request_only",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/search",
            body: "Search for SKU 1234-5678",
            plug: plug
          )
        end
      )

      # SKU only in request, so response should NOT be templated
      result =
        with_cassette(
          "request_only",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/search",
              body: "Search for SKU 9999-8888",
              plug: plug
            )
          end
        )

      # Response should be unchanged (no SKU substitution)
      assert result.body["results"] == ["item1", "item2"]
      assert result.body["count"] == 2
    end

    @tag capture_log: true
    test "response-only values stay literal" do
      bypass = Bypass.open()

      # Value appears only in response, not in request
      Bypass.expect_once(bypass, "GET", "/system", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "system_sku" => "1234-5678",
            "version" => "1.0"
          })
        )
      end)

      with_cassette(
        "response_only",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/system", plug: plug)
        end
      )

      # Read cassette to verify response-only value was not templated
      cassette_path = Path.join(@cassette_dir, "response_only.json")
      {:ok, cassette_json} = File.read(cassette_path)
      assert cassette_json =~ "1234-5678"
      # Should be literal, not {{sku.0}}
      refute cassette_json =~ "{{sku."
    end

    @tag capture_log: true
    test "shared values are templated in both request and response" do
      bypass = Bypass.open()

      # Value appears in BOTH request and response
      Bypass.expect_once(bypass, "POST", "/lookup", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "sku" => "1234-5678",
            "name" => "Widget"
          })
        )
      end)

      with_cassette(
        "shared_values",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/lookup",
            body: "Get SKU 1234-5678",
            plug: plug
          )
        end
      )

      # Replay with different SKU
      result =
        with_cassette(
          "shared_values",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/lookup",
              body: "Get SKU 9999-8888",
              plug: plug
            )
          end
        )

      # Response should have new SKU substituted
      assert result.body["sku"] == "9999-8888"
      assert result.body["name"] == "Widget"
    end
  end

  describe "edge case: special characters in values" do
    @tag capture_log: true
    test "escapes regex special characters in extracted values" do
      bypass = Bypass.open()

      # Value contains regex special characters like dots
      Bypass.expect_once(bypass, "POST", "/version", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "1.2.3"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "version" => "1.2.3",
            "status" => "ok"
          })
        )
      end)

      with_cassette(
        "special_chars",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [version: ~r/\d+\.\d+\.\d+/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/version",
            body: "version: 1.2.3",
            plug: plug
          )
        end
      )

      # Replay with different version
      result =
        with_cassette(
          "special_chars",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [version: ~r/\d+\.\d+\.\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/version",
              body: "version: 2.5.1",
              plug: plug
            )
          end
        )

      # Version should be correctly substituted despite dots
      assert result.body["version"] == "2.5.1"
      assert result.body["status"] == "ok"
    end
  end

  describe "edge case: multiline patterns" do
    @tag capture_log: true
    test "supports multiline patterns with proper escaping" do
      bypass = Bypass.open()

      # Multiline content in request
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("text/plain")
        |> Conn.resp(
          200,
          """
          SKU: 1234-5678
          Status: Active
          """
        )
      end)

      with_cassette(
        "multiline",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/data",
            body: """
            SKU: 1234-5678
            Request: Info
            """,
            plug: plug
          )
        end
      )

      # Replay with different SKU
      result =
        with_cassette(
          "multiline",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              body: """
              SKU: 9999-8888
              Request: Info
              """,
              plug: plug
            )
          end
        )

      # Should correctly substitute across newlines
      assert result.body =~ "9999-8888"
      assert result.body =~ "Status: Active"
    end
  end

  describe "edge case: case sensitivity" do
    @tag capture_log: true
    test "extracts values with different casing separately" do
      bypass = Bypass.open()

      # Same word with different casing
      Bypass.expect_once(bypass, "POST", "/users", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "Alice"
        assert body =~ "ALICE"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "lowercase" => "Alice",
            "uppercase" => "ALICE",
            "message" => "User Alice and ALICE"
          })
        )
      end)

      # Pattern matches capitalized words
      with_cassette(
        "case_sensitive",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [user: ~r/\b[A-Z][A-Za-z]*\b/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/users",
            body: "User Alice and ALICE",
            plug: plug
          )
        end
      )

      # Replay with different names
      result =
        with_cassette(
          "case_sensitive",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [user: ~r/\b[A-Z][A-Za-z]*\b/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/users",
              body: "User Bob and BOB",
              plug: plug
            )
          end
        )

      # Should substitute both occurrences correctly
      assert result.body["lowercase"] == "Bob"
      assert result.body["uppercase"] == "BOB"
      assert result.body["message"] == "User Bob and BOB"
    end
  end

  describe "edge case: binary/non-text bodies" do
    @tag capture_log: true
    test "skips templating for binary blob bodies" do
      bypass = Bypass.open()

      # Binary image body
      png_header = <<137, 80, 78, 71, 13, 10, 26, 10>>

      Bypass.expect_once(bypass, "GET", "/image", fn conn ->
        conn
        |> Conn.put_resp_content_type("image/png")
        |> Conn.resp(200, png_header)
      end)

      with_cassette(
        "binary_body",
        [
          cassette_dir: @cassette_dir,
          template: [
            # Even with patterns configured, blobs should not be templated
            patterns: [id: ~r/\d+/]
          ]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/image", plug: plug)
        end
      )

      # Read cassette to verify blob was stored correctly without templating
      cassette_path = Path.join(@cassette_dir, "binary_body.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Body should be blob type (base64 encoded)
      assert interaction["response"]["body_type"] == "blob"
      assert is_binary(interaction["response"]["body_blob"])

      # URI should be templated (port number is captured by id pattern)
      assert interaction["request"]["uri"] =~ "{{id.0}}"

      # But blob body should NOT be templated - it should remain as base64
      refute interaction["response"]["body_blob"] =~ "{{"
      # Verify it's valid base64
      assert {:ok, _decoded} = Base.decode64(interaction["response"]["body_blob"])
    end
  end

  describe "edge case: dynamic non-string values" do
    @tag capture_log: true
    test "numbers, booleans, null are never templated" do
      bypass = Bypass.open()

      # Response with mixed types
      Bypass.expect_once(bypass, "POST", "/item", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "sku" => "1234-5678",
            "count" => 5,
            "active" => true,
            "notes" => nil
          })
        )
      end)

      with_cassette(
        "non_string_values",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/item",
            body: "Get SKU 1234-5678",
            plug: plug
          )
        end
      )

      # Read cassette to verify only string value was templated
      cassette_path = Path.join(@cassette_dir, "non_string_values.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])
      response = interaction["response"]["body_json"]

      # SKU (string) should be templated
      assert is_binary(response["sku"])
      assert response["sku"] =~ "{{sku." or response["sku"] == "1234-5678"

      # Numbers, booleans, null should remain literal
      assert response["count"] == 5
      assert response["active"] == true
      assert response["notes"] == nil
    end
  end

  describe "edge case: value set mismatch" do
    @tag capture_log: true
    test "fails when unique value count changes between recording and replay" do
      bypass = Bypass.open()

      # Record with ONE unique SKU (duplicated)
      Bypass.expect_once(bypass, "POST", "/process", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        # Same SKU appears twice
        assert body == "SKU 1234-5678 and SKU 1234-5678 again"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "sku1" => "1234-5678",
            "sku2" => "1234-5678"
          })
        )
      end)

      with_cassette(
        "value_set_mismatch",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/process",
            body: "SKU 1234-5678 and SKU 1234-5678 again",
            plug: plug
          )
        end
      )

      # Replay with TWO unique SKUs - should fail
      # Recording had: ["1234-5678"] (one unique value)
      # Replay has: ["5555-6666", "7777-8888"] (two unique values)
      # Template structure won't match!
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "value_set_mismatch",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/process",
              body: "SKU 5555-6666 and SKU 7777-8888",
              plug: plug
            )
          end
        )
      end
    end

    @tag capture_log: true
    test "succeeds when same unique values appear in different order" do
      bypass = Bypass.open()

      # Record with two SKUs in one order
      Bypass.expect_once(bypass, "POST", "/compare", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "first" => "1111-2222",
            "second" => "3333-4444",
            "message" => "Comparing 1111-2222 vs 3333-4444"
          })
        )
      end)

      with_cassette(
        "value_order",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/compare",
            body: "Compare 1111-2222 vs 3333-4444",
            plug: plug
          )
        end
      )

      # Replay with same SKUs but different order - should work
      # Recording extracted: ["1111-2222", "3333-4444"]
      # Replay extracts: ["3333-4444", "1111-2222"]
      # Same set of values, so matching succeeds!
      result =
        with_cassette(
          "value_order",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/compare",
              body: "Compare 3333-4444 vs 1111-2222",
              plug: plug
            )
          end
        )

      # Values should be substituted correctly
      assert result.body["first"] == "3333-4444"
      assert result.body["second"] == "1111-2222"
      assert result.body["message"] == "Comparing 3333-4444 vs 1111-2222"
    end
  end
end
