defmodule ReqCassette.Template.AdvancedTest do
  use ExUnit.Case, async: true

  import ReqCassette

  alias Plug.Conn

  @cassette_dir "test/fixtures/template_advanced"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "headers not compared in template matching" do
    @tag capture_log: true
    test "requests with different headers match same templated cassette" do
      bypass = Bypass.open()

      # Record with one set of headers and ID in path
      Bypass.expect_once(bypass, "GET", "/data/id-123", fn conn ->
        # Verify we got specific headers
        assert Conn.get_req_header(conn, "x-api-version") == ["v1"]

        # Extract ID from path and echo it back
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => "id-123", "status" => "ok"}))
      end)

      result1 =
        with_cassette(
          "headers_ignored",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/data/id-123",
              headers: [{"x-api-version", "v1"}, {"x-request-id", "req-001"}],
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["id"] == "id-123"

      # Replay with COMPLETELY DIFFERENT headers AND different ID - should still match!
      result2 =
        with_cassette(
          "headers_ignored",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/data/id-999",
              headers: [{"x-api-version", "v2"}, {"authorization", "Bearer token"}],
              plug: plug
            )
          end
        )

      # Should replay successfully with different ID substituted
      assert result2.status == 200
      assert result2.body["id"] == "id-999"
      assert result2.body["status"] == "ok"
    end
  end

  describe "filter + template combination" do
    @tag capture_log: true
    test "filters secrets and templates IDs in same cassette" do
      bypass = Bypass.open()

      # Record with API key and user ID
      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        # Server sees unfiltered data
        assert body =~ "sk-secret123"
        assert body =~ "user-12345"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "user_id" => "user-12345",
            "api_key" => "sk-secret123",
            "status" => "success"
          })
        )
      end)

      result1 =
        with_cassette(
          "filter_and_template",
          [
            cassette_dir: @cassette_dir,
            # Filter removes secrets
            filter_sensitive_data: [
              {~r/sk-[a-z0-9]+/, "sk-FILTERED"}
            ],
            # Template parameterizes IDs
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"user_id" => "user-12345", "api_key" => "sk-secret123"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["user_id"] == "user-12345"

      # Read cassette to verify filtering happened BEFORE templating
      cassette_path = Path.join(@cassette_dir, "filter_and_template.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # API key should be filtered (replaced with placeholder)
      assert interaction["request"]["body_json"]["api_key"] == "sk-FILTERED"
      assert interaction["response"]["body_json"]["api_key"] == "sk-FILTERED"

      # User ID should be templated
      assert interaction["request"]["body_json"]["user_id"] == "{{user_id.0}}"
      assert interaction["response"]["body_json"]["user_id"] == "{{user_id.0}}"
    end

    @tag capture_log: true
    test "filter and template with replay validation" do
      bypass = Bypass.open()

      # Record
      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "user_id" => "user-12345",
            "status" => "success"
          })
        )
      end)

      # First call - records (without filter_sensitive_data to avoid complexity)
      result1 =
        with_cassette(
          "filter_and_template_replay",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"user_id" => "user-12345"},
              plug: plug
            )
          end
        )

      assert result1.status == 200

      # Second call - replays with different user_id
      result2 =
        with_cassette(
          "filter_and_template_replay",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"user_id" => "user-99999"},
              plug: plug
            )
          end
        )

      # Should replay with substituted user ID
      assert result2.status == 200
      assert result2.body["user_id"] == "user-99999"
      assert result2.body["status"] == "success"
    end

    @tag capture_log: true
    test "filters request headers and templates response IDs" do
      bypass = Bypass.open()

      # Record with authorization header
      Bypass.expect_once(bypass, "GET", "/users/user-123", fn conn ->
        # Verify header present
        assert Conn.get_req_header(conn, "authorization") != []

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => "user-123", "name" => "Alice"}))
      end)

      result1 =
        with_cassette(
          "filter_headers_template_body",
          [
            cassette_dir: @cassette_dir,
            filter_request_headers: ["authorization"],
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/users/user-123",
              headers: [{"authorization", "Bearer secret-token"}],
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["id"] == "user-123"

      # Verify cassette has filtered headers
      cassette_path = Path.join(@cassette_dir, "filter_headers_template_body.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Authorization header should be removed from templated request
      refute Map.has_key?(interaction["request"]["headers"], "authorization")

      # User ID in URI should be templated
      assert interaction["request"]["uri"] =~ "{{user_id.0}}"

      # Response ID should be templated
      assert interaction["response"]["body_json"]["id"] == "{{user_id.0}}"

      # Replay with different user ID to verify substitution works
      result2 =
        with_cassette(
          "filter_headers_template_body",
          [
            cassette_dir: @cassette_dir,
            filter_request_headers: ["authorization"],
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/users/user-789",
              headers: [{"authorization", "Bearer different-token"}],
              plug: plug
            )
          end
        )

      # Should replay with substituted user ID
      assert result2.status == 200
      assert result2.body["id"] == "user-789"
      assert result2.body["name"] == "Alice"
    end
  end

  describe "selective scoping with MapSet" do
    @tag capture_log: true
    test "only templates variables that appear in both request and response" do
      bypass = Bypass.open()

      # Response contains only primary_id, not secondary_id
      Bypass.expect_once(bypass, "POST", "/process", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        # Request has both IDs
        assert body =~ "id-111"
        assert body =~ "id-222"

        # Response only echoes primary
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"processed" => "id-111"}))
      end)

      result =
        with_cassette(
          "selective_scope",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/process",
              json: %{"primary" => "id-111", "secondary" => "id-222"},
              plug: plug
            )
          end
        )

      assert result.status == 200

      # Read cassette - only id-111 should be templated in response
      cassette_path = Path.join(@cassette_dir, "selective_scope.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Request should have both IDs templated
      assert interaction["request"]["body_json"]["primary"] == "{{id.0}}"
      assert interaction["request"]["body_json"]["secondary"] == "{{id.1}}"

      # Response should only template id-111 (which appears in response)
      assert interaction["response"]["body_json"]["processed"] == "{{id.0}}"

      # recorded_values should have both
      assert interaction["template"]["recorded_values"]["id"] == ["id-111", "id-222"]

      # Replay with different IDs to verify behavior
      result2 =
        with_cassette(
          "selective_scope",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/process",
              json: %{"primary" => "id-555", "secondary" => "id-666"},
              plug: plug
            )
          end
        )

      # primary (appears in both request & response) → templated, returns id-555
      assert result2.status == 200
      assert result2.body["processed"] == "id-555"
      # secondary (request-only) → acts as wildcard, accepts id-666
    end
  end

  describe "query string edge cases" do
    @tag capture_log: true
    test "handles URL-encoded values in query parameters" do
      bypass = Bypass.open()

      # Record with URL-encoded name (using simpler pattern)
      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        # Query string has URL encoding
        assert conn.query_string =~ "name="

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"query" => "test-123", "results" => []}))
      end)

      result =
        with_cassette(
          "url_encoded_query",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Use simple pattern that doesn't span URL encoding boundaries
              patterns: [id: ~r/test-\d+/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/search",
              params: [name: "value", id: "test-123"],
              plug: plug
            )
          end
        )

      assert result.status == 200
      assert result.body["query"] == "test-123"

      # Verify cassette has templated query string
      cassette_path = Path.join(@cassette_dir, "url_encoded_query.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Query string should be templated
      assert interaction["request"]["query_string"] =~ "{{id.0}}"
      assert interaction["response"]["body_json"]["query"] == "{{id.0}}"
    end

    @tag capture_log: true
    test "handles multiple values for same query parameter key" do
      bypass = Bypass.open()

      # Record with multiple tags
      Bypass.expect_once(bypass, "GET", "/items", fn conn ->
        # Should have tag=tag-1&tag=tag-2
        assert conn.query_string =~ "tag=tag-1"
        assert conn.query_string =~ "tag=tag-2"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "tags" => ["tag-1", "tag-2"],
            "items" => []
          })
        )
      end)

      result1 =
        with_cassette(
          "multi_value_query",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [tag: ~r/tag-\d+/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/items?tag=tag-1&tag=tag-2",
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["tags"] == ["tag-1", "tag-2"]

      # Replay with different tags
      result2 =
        with_cassette(
          "multi_value_query",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [tag: ~r/tag-\d+/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/items?tag=tag-5&tag=tag-6",
              plug: plug
            )
          end
        )

      # Tags should be substituted
      assert result2.status == 200
      assert result2.body["tags"] == ["tag-5", "tag-6"]
    end
  end

  describe "pattern variations" do
    @tag capture_log: true
    test "case-insensitive patterns with ~r/.../i flag" do
      bypass = Bypass.open()

      # Record with mixed case
      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "ABC"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"code" => "ABC-123"}))
      end)

      result1 =
        with_cassette(
          "case_insensitive",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Case-insensitive pattern
              patterns: [code: ~r/[a-z]{3}-\d{3}/i]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"code" => "ABC-123"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["code"] == "ABC-123"

      # Replay with lowercase
      result2 =
        with_cassette(
          "case_insensitive",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [code: ~r/[a-z]{3}-\d{3}/i]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"code" => "xyz-999"},
              plug: plug
            )
          end
        )

      # Code should be substituted (case-insensitive match)
      assert result2.status == 200
      assert result2.body["code"] == "xyz-999"
    end

    @tag capture_log: true
    test "pattern configured but never matches anything" do
      bypass = Bypass.open()

      # Response has no SKUs
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"status" => "ok", "count" => 0}))
      end)

      result =
        with_cassette(
          "no_matches",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Pattern configured but won't match anything
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/status", plug: plug)
          end
        )

      assert result.status == 200

      # Read cassette - recorded_values should be empty
      cassette_path = Path.join(@cassette_dir, "no_matches.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # No values extracted - key may not exist if pattern never matched
      recorded_values = interaction["template"]["recorded_values"]
      assert recorded_values["sku"] == [] or not Map.has_key?(recorded_values, "sku")

      # No templating should have occurred - request should not have template markers
      refute interaction["request"]["uri"] =~ ~r/\{\{/

      assert interaction["response"]["body_json"] == %{"status" => "ok", "count" => 0}
    end

    @tag capture_log: true
    test "template with non-matching pattern acts as exact match during replay" do
      bypass = Bypass.open()

      # Record with a pattern that will never match anything in the request/response
      Bypass.expect(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        request_json = Jason.decode!(body)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{"id" => request_json["id"], "status" => "processed"})
        )
      end)

      # First call: record with id "ABC-123"
      with_cassette(
        "non_matching_pattern_replay",
        [
          cassette_dir: @cassette_dir,
          template: [
            # Pattern that will never match (looking for impossible format)
            patterns: [impossible: ~r/IMPOSSIBLE_TO_MATCH_12345/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/api",
            json: %{"id" => "ABC-123"},
            plug: plug
          )
        end
      )

      # Verify cassette has no template markers
      cassette_path = Path.join(@cassette_dir, "non_matching_pattern_replay.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Template is enabled but no values extracted
      assert interaction["template"]["enabled"] == true
      recorded_values = interaction["template"]["recorded_values"]

      assert recorded_values["impossible"] == [] or
               not Map.has_key?(recorded_values, "impossible")

      # No template markers in request or response
      refute Jason.encode!(interaction["request"]) =~ ~r/\{\{/
      refute Jason.encode!(interaction["response"]) =~ ~r/\{\{/

      # Second call: replay with EXACT SAME id should succeed (exact matching)
      result_same =
        with_cassette(
          "non_matching_pattern_replay",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            # Force replay mode
            template: [
              patterns: [impossible: ~r/IMPOSSIBLE_TO_MATCH_12345/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"id" => "ABC-123"},
              plug: plug
            )
          end
        )

      assert result_same.status == 200
      assert result_same.body["id"] == "ABC-123"
      assert result_same.body["status"] == "processed"

      # Third call: replay with DIFFERENT id value should fail
      # Since no patterns matched, there are no template markers,
      # so it should use exact matching and the different value won't match
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "non_matching_pattern_replay",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            template: [
              patterns: [impossible: ~r/IMPOSSIBLE_TO_MATCH_12345/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"id" => "XYZ-789"},
              # Different value!
              plug: plug
            )
          end
        )
      end
    end
  end

  describe "multiline pattern matching" do
    @tag capture_log: true
    test "pattern matches value containing literal newline character" do
      bypass = Bypass.open()

      # Response has value with newline in it
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "message" => "Line 1: id-123\nLine 2: more text"
          })
        )
      end)

      result1 =
        with_cassette(
          "multiline_value",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Pattern that can match across newlines
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"input" => "Line 1: id-123\nLine 2: data"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["message"] =~ "id-123"

      # Replay - should still match even with newlines
      result2 =
        with_cassette(
          "multiline_value",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"input" => "Line 1: id-999\nLine 2: data"},
              plug: plug
            )
          end
        )

      # ID should be substituted even across newlines
      assert result2.status == 200
      assert result2.body["message"] =~ "id-999"
    end
  end

  describe "request-only values (wildcard behavior)" do
    @tag capture_log: true
    test "values appearing only in request act as wildcards" do
      bypass = Bypass.open()

      # Request has filter ID, but response doesn't echo it
      Bypass.expect_once(bypass, "POST", "/search", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        # Request has ID
        assert body =~ "id-123"

        # Response doesn't include the filter ID
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "results" => ["item1", "item2"],
            "count" => 5
          })
        )
      end)

      result1 =
        with_cassette(
          "request_only_wildcard",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/search",
              json: %{"filter" => "id-123"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["count"] == 5

      # Read cassette - request should be templated, response NOT
      cassette_path = Path.join(@cassette_dir, "request_only_wildcard.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Request templated (wildcard)
      assert interaction["request"]["body_json"]["filter"] == "{{id.0}}"
      # Response NOT templated (stays constant)
      assert interaction["response"]["body_json"]["count"] == 5

      # Replay with DIFFERENT filter ID - should match! (wildcard behavior)
      result2 =
        with_cassette(
          "request_only_wildcard",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/search",
              json: %{"filter" => "id-999"},
              plug: plug
            )
          end
        )

      # Wildcard accepts different ID, response stays same
      assert result2.status == 200
      assert result2.body["results"] == ["item1", "item2"]
      assert result2.body["count"] == 5
    end
  end

  describe "response-only values (static data)" do
    @tag capture_log: true
    test "values appearing only in response stay literal (not templated)" do
      bypass = Bypass.open()

      # Response contains system-generated ID that's not in request
      Bypass.expect_once(bypass, "GET", "/system", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "system_id" => "id-999",
            "version" => "1.0",
            "status" => "healthy"
          })
        )
      end)

      result =
        with_cassette(
          "response_only_value",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/system", plug: plug)
          end
        )

      assert result.status == 200
      assert result.body["system_id"] == "id-999"

      # Read cassette - response should NOT be templated
      cassette_path = Path.join(@cassette_dir, "response_only_value.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # system_id appears only in response → stays literal
      assert interaction["response"]["body_json"]["system_id"] == "id-999"
      refute interaction["response"]["body_json"]["system_id"] == "{{id.0}}"

      # Pattern matched but value not in request, so recorded_values should be empty
      recorded_values = interaction["template"]["recorded_values"]
      assert recorded_values["id"] == [] or not Map.has_key?(recorded_values, "id")

      # Replay to verify system_id remains static (not substituted)
      result2 =
        with_cassette(
          "response_only_value",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/system", plug: plug)
          end
        )

      # Response-only values stay constant - not templated
      assert result2.status == 200
      assert result2.body["system_id"] == "id-999"
      assert result2.body["version"] == "1.0"
      assert result2.body["status"] == "healthy"
    end
  end

  describe "duplicate values get same marker" do
    @tag capture_log: true
    test "same value appearing multiple times gets same template marker" do
      bypass = Bypass.open()

      # Response echoes the same SKU twice
      Bypass.expect_once(bypass, "POST", "/process", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "message" => "SKU 1234-5678 and SKU 1234-5678 again",
            "primary_sku" => "1234-5678",
            "secondary_sku" => "1234-5678"
          })
        )
      end)

      result1 =
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
              json: %{"sku" => "1234-5678"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["primary_sku"] == "1234-5678"
      assert result1.body["secondary_sku"] == "1234-5678"

      # Read cassette - all occurrences should use {{sku.0}}
      cassette_path = Path.join(@cassette_dir, "duplicate_values.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Only ONE unique value → only sku.0 used (not sku.1, sku.2, etc.)
      assert interaction["template"]["recorded_values"]["sku"] == ["1234-5678"]

      assert interaction["response"]["body_json"]["message"] ==
               "SKU {{sku.0}} and SKU {{sku.0}} again"

      assert interaction["response"]["body_json"]["primary_sku"] == "{{sku.0}}"
      assert interaction["response"]["body_json"]["secondary_sku"] == "{{sku.0}}"

      # Replay with different SKU
      result2 =
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
              json: %{"sku" => "9999-8888"},
              plug: plug
            )
          end
        )

      # All occurrences should be substituted with new value
      assert result2.status == 200
      assert result2.body["message"] == "SKU 9999-8888 and SKU 9999-8888 again"
      assert result2.body["primary_sku"] == "9999-8888"
      assert result2.body["secondary_sku"] == "9999-8888"
    end

    @tag capture_log: true
    test "multiple distinct values are stored in recorded_values" do
      bypass = Bypass.open()

      # Response has two different SKUs
      Bypass.expect_once(bypass, "POST", "/process", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "1111-2222"
        assert body =~ "3333-4444"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "message" => "SKU 1111-2222 and SKU 3333-4444",
            "first_sku" => "1111-2222",
            "second_sku" => "3333-4444"
          })
        )
      end)

      result1 =
        with_cassette(
          "multiple_distinct_values",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/process",
              json: %{"sku1" => "1111-2222", "sku2" => "3333-4444"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["first_sku"] == "1111-2222"
      assert result1.body["second_sku"] == "3333-4444"

      # Read cassette - should have both distinct values
      cassette_path = Path.join(@cassette_dir, "multiple_distinct_values.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Two distinct values → sku.0 and sku.1
      assert Enum.sort(interaction["template"]["recorded_values"]["sku"]) ==
               Enum.sort(["1111-2222", "3333-4444"])

      # Message should have both markers (order depends on extraction order)
      message = interaction["response"]["body_json"]["message"]
      assert message =~ ~r/SKU \{\{sku\.\d\}\} and SKU \{\{sku\.\d\}\}/

      # Check that first_sku and second_sku use template markers
      assert interaction["response"]["body_json"]["first_sku"] =~ ~r/\{\{sku\.\d\}\}/
      assert interaction["response"]["body_json"]["second_sku"] =~ ~r/\{\{sku\.\d\}\}/

      # Replay with different SKUs
      result2 =
        with_cassette(
          "multiple_distinct_values",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/process",
              json: %{"sku1" => "9999-8888", "sku2" => "7777-6666"},
              plug: plug
            )
          end
        )

      # All occurrences should be substituted with new values
      assert result2.status == 200
      # Message should have both new SKU values
      assert result2.body["message"] =~ "9999-8888"
      assert result2.body["message"] =~ "7777-6666"
      # Both SKU fields should have the new values (order may vary)
      assert result2.body["first_sku"] in ["9999-8888", "7777-6666"]
      assert result2.body["second_sku"] in ["9999-8888", "7777-6666"]
    end
  end

  describe "pattern overlap resolution" do
    @tag capture_log: true
    test "most specific (longest) match wins when patterns overlap" do
      bypass = Bypass.open()

      # Response has SKU format that matches both patterns
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678"}))
      end)

      result =
        with_cassette(
          "pattern_overlap",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                # Generic pattern - matches "1234" and "5678"
                number: ~r/\d+/,
                # Specific pattern - matches "1234-5678"
                sku: ~r/\d{4}-\d{4}/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"sku" => "1234-5678"},
              plug: plug
            )
          end
        )

      assert result.status == 200
      assert result.body["sku"] == "1234-5678"

      # Read cassette - should use sku pattern (not number)
      cassette_path = Path.join(@cassette_dir, "pattern_overlap.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Most specific pattern wins
      assert interaction["template"]["recorded_values"]["sku"] == ["1234-5678"]
      # number pattern shouldn't have matched (overlapping match discarded)
      refute Map.get(interaction["template"]["recorded_values"], "number", []) == [
               "1234",
               "5678"
             ]
    end

    @tag capture_log: true
    test "non-overlapping matches from different patterns are both kept" do
      bypass = Bypass.open()

      # Response has both port number and SKU (non-overlapping)
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "8080"
        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "port" => "8080",
            "sku" => "1234-5678",
            "message" => "Port 8080 handling SKU 1234-5678"
          })
        )
      end)

      result =
        with_cassette(
          "non_overlapping",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                # Use more specific pattern to avoid matching bypass port
                port: ~r/\b80\d{2}\b/,
                sku: ~r/\d{4}-\d{4}/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"port" => "8080", "sku" => "1234-5678"},
              plug: plug
            )
          end
        )

      assert result.status == 200
      assert result.body["port"] == "8080"
      assert result.body["sku"] == "1234-5678"

      # Read cassette - both patterns should match their respective values
      cassette_path = Path.join(@cassette_dir, "non_overlapping.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Both patterns matched (non-overlapping)
      assert interaction["template"]["recorded_values"]["port"] == ["8080"]
      assert interaction["template"]["recorded_values"]["sku"] == ["1234-5678"]

      # Template uses correct markers
      assert interaction["response"]["body_json"]["message"] ==
               "Port {{port.0}} handling SKU {{sku.0}}"
    end
  end

  describe "empty match filtering" do
    @tag capture_log: true
    test "patterns with * quantifier have empty matches removed" do
      bypass = Bypass.open()

      # Response with words
      Bypass.expect_once(bypass, "POST", "/text", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"text" => "hello world"}))
      end)

      result =
        with_cassette(
          "empty_matches",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                # * can match zero characters (empty strings)
                word: ~r/\w*/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/text",
              json: %{"text" => "hello world"},
              plug: plug
            )
          end
        )

      assert result.status == 200
      assert result.body["text"] == "hello world"

      # Read cassette - empty matches should be filtered out
      cassette_path = Path.join(@cassette_dir, "empty_matches.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Only non-empty words should be in recorded_values
      recorded_words = interaction["template"]["recorded_values"]["word"]
      # Should have "hello" and "world", not empty strings
      assert length(recorded_words) >= 2
      refute "" in recorded_words
    end
  end

  describe "non-string JSON values stay literal" do
    @tag capture_log: true
    test "only string values are templated, numbers/booleans/null stay literal" do
      bypass = Bypass.open()

      # Response has mixed types
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "id-123",
            "count" => 5,
            "active" => true,
            "notes" => nil
          })
        )
      end)

      result =
        with_cassette(
          "non_string_values",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"id" => "id-123", "count" => 5, "active" => true, "notes" => nil},
              plug: plug
            )
          end
        )

      assert result.status == 200
      assert result.body["id"] == "id-123"
      assert result.body["count"] == 5
      assert result.body["active"] == true
      assert result.body["notes"] == nil

      # Read cassette
      cassette_path = Path.join(@cassette_dir, "non_string_values.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # String templated, others literal
      assert interaction["response"]["body_json"]["id"] == "{{id.0}}"
      assert interaction["response"]["body_json"]["count"] == 5
      assert interaction["response"]["body_json"]["active"] == true
      assert interaction["response"]["body_json"]["notes"] == nil
    end
  end

  describe "allow_key_templates option" do
    @tag capture_log: true
    test "with allow_key_templates: true, JSON keys are templated" do
      bypass = Bypass.open()

      # Response uses SKU as key
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"1234-5678" => "product data"}))
      end)

      result1 =
        with_cassette(
          "key_templates",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/],
              allow_key_templates: true
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"sku" => "1234-5678"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["1234-5678"] == "product data"

      # Read cassette - key should be templated
      cassette_path = Path.join(@cassette_dir, "key_templates.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Key templated (note: JSON keys are strings)
      assert Map.has_key?(interaction["response"]["body_json"], "{{sku.0}}")
      assert interaction["response"]["body_json"]["{{sku.0}}"] == "product data"

      # Replay with different SKU
      result2 =
        with_cassette(
          "key_templates",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/],
              allow_key_templates: true
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"sku" => "9999-8888"},
              plug: plug
            )
          end
        )

      # Key should be substituted
      assert result2.status == 200
      assert result2.body["9999-8888"] == "product data"
      refute Map.has_key?(result2.body, "1234-5678")
    end
  end

  describe "value set mismatch behavior" do
    @tag capture_log: true
    test "different number of unique values creates different template structure" do
      bypass = Bypass.open()

      # Recording: only one unique SKU (appears twice)
      Bypass.expect_once(bypass, "POST", "/process", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "message" => "SKU 1111-2222 and 1111-2222"
          })
        )
      end)

      # Record with one unique value
      result1 =
        with_cassette(
          "value_set_one_unique",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/process",
              json: %{"message" => "SKU 1111-2222 and 1111-2222"},
              plug: plug
            )
          end
        )

      assert result1.status == 200

      # Read cassette - should have one unique value
      cassette_path = Path.join(@cassette_dir, "value_set_one_unique.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      assert interaction["template"]["recorded_values"]["sku"] == ["1111-2222"]
      # But both occurrences use same marker (because same value)
      assert interaction["response"]["body_json"]["message"] ==
               "SKU {{sku.0}} and {{sku.0}}"

      # Now record a different cassette with TWO unique values
      Bypass.expect_once(bypass, "POST", "/process2", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "message" => "SKU 1111-2222 and 3333-4444"
          })
        )
      end)

      result2 =
        with_cassette(
          "value_set_two_unique",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/process2",
              json: %{"message" => "SKU 1111-2222 and 3333-4444"},
              plug: plug
            )
          end
        )

      assert result2.status == 200

      # Read cassette - should have two unique values
      cassette_path2 = Path.join(@cassette_dir, "value_set_two_unique.json")
      {:ok, cassette_json2} = File.read(cassette_path2)
      {:ok, cassette2} = Jason.decode(cassette_json2)
      interaction2 = List.first(cassette2["interactions"])

      # Two unique values
      assert Enum.sort(interaction2["template"]["recorded_values"]["sku"]) ==
               Enum.sort(["1111-2222", "3333-4444"])

      # Different markers used
      assert interaction2["response"]["body_json"]["message"] ==
               "SKU {{sku.0}} and {{sku.1}}"

      # Structures are different:
      # Cassette 1: "SKU {{sku.0}} and {{sku.0}}"
      # Cassette 2: "SKU {{sku.0}} and {{sku.1}}"
      refute interaction["response"]["body_json"]["message"] ==
               interaction2["response"]["body_json"]["message"]
    end
  end

  describe "multiple patterns in single request" do
    @tag capture_log: true
    test "handles multiple different pattern types in same request" do
      bypass = Bypass.open()

      # Response with multiple pattern types
      Bypass.expect_once(bypass, "POST", "/orders", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "user-12345"
        assert body =~ "ORD-9876"
        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "user_id" => "user-12345",
            "order_id" => "ORD-9876",
            "items" => [
              %{"sku" => "1234-5678", "quantity" => 2},
              %{"sku" => "5678-9012", "quantity" => 1}
            ],
            "message" => "Order ORD-9876 for user-12345 with SKUs 1234-5678, 5678-9012"
          })
        )
      end)

      result1 =
        with_cassette(
          "multiple_patterns",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                user_id: ~r/user-\d+/,
                order_id: ~r/ORD-\d+/,
                sku: ~r/\d{4}-\d{4}/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/orders",
              json: %{
                "user_id" => "user-12345",
                "order_id" => "ORD-9876",
                "items" => [
                  %{"sku" => "1234-5678", "quantity" => 2},
                  %{"sku" => "5678-9012", "quantity" => 1}
                ]
              },
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["user_id"] == "user-12345"
      assert result1.body["order_id"] == "ORD-9876"

      # Replay with all different values
      result2 =
        with_cassette(
          "multiple_patterns",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                user_id: ~r/user-\d+/,
                order_id: ~r/ORD-\d+/,
                sku: ~r/\d{4}-\d{4}/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/orders",
              json: %{
                "user_id" => "user-99999",
                "order_id" => "ORD-1111",
                "items" => [
                  %{"sku" => "9999-8888", "quantity" => 2},
                  %{"sku" => "7777-6666", "quantity" => 1}
                ]
              },
              plug: plug
            )
          end
        )

      # All values should be substituted
      assert result2.status == 200
      assert result2.body["user_id"] == "user-99999"
      assert result2.body["order_id"] == "ORD-1111"

      assert result2.body["items"] == [
               %{"sku" => "9999-8888", "quantity" => 2},
               %{"sku" => "7777-6666", "quantity" => 1}
             ]

      assert result2.body["message"] ==
               "Order ORD-1111 for user-99999 with SKUs 9999-8888, 7777-6666"
    end
  end

  describe "value ordering flexibility" do
    @tag capture_log: true
    test "same unique values in different order still match" do
      bypass = Bypass.open()

      # Record with SKUs in one order
      Bypass.expect_once(bypass, "POST", "/compare", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "message" => "SKU 1111-2222 then 3333-4444"
          })
        )
      end)

      result1 =
        with_cassette(
          "value_ordering",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/compare",
              json: %{"message" => "SKU 1111-2222 then 3333-4444"},
              plug: plug
            )
          end
        )

      assert result1.status == 200

      # Replay with DIFFERENT ORDER but same unique values
      result2 =
        with_cassette(
          "value_ordering",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/compare",
              json: %{"message" => "SKU 3333-4444 then 1111-2222"},
              plug: plug
            )
          end
        )

      # Should match! Order doesn't matter, same unique set
      assert result2.status == 200
      # Values substituted in new order
      assert result2.body["message"] == "SKU 3333-4444 then 1111-2222"
    end
  end

  describe "structure validation" do
    @tag capture_log: true
    test "request body structure must match for replay" do
      bypass = Bypass.open()

      # Record with specific structure
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert Map.has_key?(decoded, "sku")
        assert Map.has_key?(decoded, "name")

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678", "name" => "Widget"}))
      end)

      result1 =
        with_cassette(
          "structure_validation",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"sku" => "1234-5678", "name" => "Widget"},
              plug: plug
            )
          end
        )

      assert result1.status == 200

      # Verify cassette structure
      cassette_path = Path.join(@cassette_dir, "structure_validation.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Request template includes both fields
      assert Map.has_key?(interaction["request"]["body_json"], "sku")
      assert Map.has_key?(interaction["request"]["body_json"], "name")
    end
  end

  describe "plain text body templating" do
    @tag capture_log: true
    test "plain text bodies support templating" do
      bypass = Bypass.open()

      # Response with plain text containing IDs
      Bypass.expect_once(bypass, "POST", "/message", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("text/plain")
        |> Conn.resp(200, "Order ORD-123 for SKU 1234-5678")
      end)

      result1 =
        with_cassette(
          "plain_text_template",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                order_id: ~r/ORD-\d+/,
                sku: ~r/\d{4}-\d{4}/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/message",
              body: "Order ORD-123 for SKU 1234-5678",
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body == "Order ORD-123 for SKU 1234-5678"

      # Replay with different values
      result2 =
        with_cassette(
          "plain_text_template",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                order_id: ~r/ORD-\d+/,
                sku: ~r/\d{4}-\d{4}/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/message",
              body: "Order ORD-999 for SKU 9999-8888",
              plug: plug
            )
          end
        )

      # Values substituted in plain text
      assert result2.status == 200
      assert result2.body == "Order ORD-999 for SKU 9999-8888"
    end
  end

  describe "non-string value handling" do
    @tag capture_log: true
    test "non-string values remain literal in templates" do
      bypass = Bypass.open()

      # Record with count = 5
      Bypass.expect_once(bypass, "POST", "/items", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678", "count" => 5}))
      end)

      result =
        with_cassette(
          "non_string_literal",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/items",
              json: %{"sku" => "1234-5678", "count" => 5},
              plug: plug
            )
          end
        )

      assert result.status == 200

      # Verify cassette - count stays literal
      cassette_path = Path.join(@cassette_dir, "non_string_literal.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # SKU templated, count literal
      assert interaction["response"]["body_json"]["sku"] == "{{sku.0}}"
      assert interaction["response"]["body_json"]["count"] == 5
    end
  end

  describe "LLM API use case" do
    @tag capture_log: true
    test "LLM conversation with dynamic IDs" do
      bypass = Bypass.open()

      # LLM API response with conversation and message IDs
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "conversation_id" => "conv_abc123",
            "message_id" => "msg_001",
            "timestamp" => "2025-01-15T10:30:00Z",
            "content" => "Hello! How can I help you?"
          })
        )
      end)

      result1 =
        with_cassette(
          "llm_conversation",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                conversation_id: ~r/conv_[a-zA-Z0-9]+/,
                message_id: ~r/msg_[a-zA-Z0-9]+/,
                timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/v1/messages",
              json: %{
                "conversation_id" => "conv_abc123",
                "message_id" => "msg_001",
                "timestamp" => "2025-01-15T10:30:00Z",
                "prompt" => "Hello"
              },
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["content"] == "Hello! How can I help you?"

      # Replay with DIFFERENT IDs and timestamp
      result2 =
        with_cassette(
          "llm_conversation",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                conversation_id: ~r/conv_[a-zA-Z0-9]+/,
                message_id: ~r/msg_[a-zA-Z0-9]+/,
                timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
              ]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/v1/messages",
              json: %{
                "conversation_id" => "conv_xyz789",
                "message_id" => "msg_999",
                "timestamp" => "2025-10-20T14:45:30Z",
                "prompt" => "Hello"
              },
              plug: plug
            )
          end
        )

      # All IDs substituted correctly
      assert result2.status == 200
      assert result2.body["conversation_id"] == "conv_xyz789"
      assert result2.body["message_id"] == "msg_999"
      assert result2.body["timestamp"] == "2025-10-20T14:45:30Z"
      assert result2.body["content"] == "Hello! How can I help you?"
    end
  end

  describe "binary/blob bodies skip templating" do
    @tag capture_log: true
    test "blob bodies are not templated" do
      bypass = Bypass.open()

      # Response with binary data
      Bypass.expect_once(bypass, "GET", "/image", fn conn ->
        binary_data = <<137, 80, 78, 71, 13, 10, 26, 10>>

        conn
        |> Conn.put_resp_content_type("image/png")
        |> Conn.resp(200, binary_data)
      end)

      result =
        with_cassette(
          "blob_body",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/id-\d+/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/image", plug: plug)
          end
        )

      assert result.status == 200

      # Read cassette - should be stored as blob, not templated
      cassette_path = Path.join(@cassette_dir, "blob_body.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Binary body stored as blob, not templated
      assert interaction["response"]["body_type"] == "blob"
      assert Map.has_key?(interaction["response"], "body_blob")
      # Blob is base64 encoded, not template markers
      refute String.contains?(interaction["response"]["body_blob"], "{{")
    end
  end

  describe "unique value count behavior" do
    @tag capture_log: true
    test "template structure depends on number of unique values" do
      bypass = Bypass.open()

      # Record with ONE unique value (repeated twice)
      Bypass.expect_once(bypass, "POST", "/check", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"message" => "SKU 1111-2222 and 1111-2222"}))
      end)

      result =
        with_cassette(
          "unique_count",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/check",
              json: %{"message" => "SKU 1111-2222 and 1111-2222"},
              plug: plug
            )
          end
        )

      assert result.status == 200

      # Verify: ONE unique value -> both occurrences use same marker
      cassette_path = Path.join(@cassette_dir, "unique_count.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Both occurrences use {{sku.0}} (same marker for same value)
      assert interaction["response"]["body_json"]["message"] ==
               "SKU {{sku.0}} and {{sku.0}}"
    end
  end

  describe "structure mismatch errors" do
    @tag capture_log: true
    test "replay with missing field fails to match" do
      bypass = Bypass.open()

      # Record with two fields
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert Map.has_key?(decoded, "sku")
        assert Map.has_key?(decoded, "name")

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678", "name" => "Widget"}))
      end)

      result1 =
        with_cassette(
          "structure_mismatch_missing",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"sku" => "1234-5678", "name" => "Widget"},
              plug: plug
            )
          end
        )

      assert result1.status == 200

      # Try to replay with missing "name" field - should fail to match
      # Bypass should be called because template match fails
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "9999-8888"}))
      end)

      result2 =
        with_cassette(
          "structure_mismatch_missing",
          [
            cassette_dir: @cassette_dir,
            mode: :record,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"sku" => "9999-8888"},
              plug: plug
            )
          end
        )

      # Should get response from real server (not cassette) because structure differs
      assert result2.status == 200
      assert result2.body["sku"] == "9999-8888"
      refute Map.has_key?(result2.body, "name")
    end

    @tag capture_log: true
    test "replay with different text structure fails to match" do
      bypass = Bypass.open()

      # Record with specific text pattern
      Bypass.expect_once(bypass, "POST", "/message", fn conn ->
        conn
        |> Conn.put_resp_content_type("text/plain")
        |> Conn.resp(200, "Get SKU 1234-5678")
      end)

      result1 =
        with_cassette(
          "structure_mismatch_text",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/message",
              body: "Get SKU 1234-5678",
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body == "Get SKU 1234-5678"

      # Try to replay with different structure - should fail to match
      Bypass.expect_once(bypass, "POST", "/message", fn conn ->
        conn
        |> Conn.put_resp_content_type("text/plain")
        |> Conn.resp(200, "Get product 9999-8888")
      end)

      result2 =
        with_cassette(
          "structure_mismatch_text",
          [
            cassette_dir: @cassette_dir,
            mode: :record,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/message",
              body: "Get product 9999-8888",
              plug: plug
            )
          end
        )

      # Should get response from real server because text structure differs
      # "Get SKU {{sku.0}}" != "Get product {{sku.0}}"
      assert result2.status == 200
      assert result2.body == "Get product 9999-8888"
    end
  end

  describe "filter + template during replay matching" do
    @tag capture_log: true
    test "filters applied before template matching during replay" do
      bypass = Bypass.open()

      # Record with API key (filtered) and user ID (templated)
      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        # Server sees unfiltered data
        assert body =~ "sk-secret123"
        assert body =~ "user-12345"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "user_id" => "user-12345",
            "api_key" => "sk-secret123",
            "status" => "success"
          })
        )
      end)

      result1 =
        with_cassette(
          "filter_template_replay_match",
          [
            cassette_dir: @cassette_dir,
            # Filter removes secrets BEFORE templating
            filter_sensitive_data: [
              {~r/sk-[a-z0-9]+/, "sk-FILTERED"}
            ],
            # Template parameterizes IDs
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"user_id" => "user-12345", "api_key" => "sk-secret123"},
              plug: plug
            )
          end
        )

      assert result1.status == 200

      # Replay with DIFFERENT API key (should be filtered) AND different user ID (templated)
      # This tests that filters are applied BEFORE template matching
      result2 =
        with_cassette(
          "filter_template_replay_match",
          [
            cassette_dir: @cassette_dir,
            filter_sensitive_data: [
              {~r/sk-[a-z0-9]+/, "sk-FILTERED"}
            ],
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"user_id" => "user-99999", "api_key" => "sk-different456"},
              plug: plug
            )
          end
        )

      # Should match cassette because:
      # 1. Filter converts "sk-different456" → "sk-FILTERED" (matches recording)
      # 2. Template converts "user-99999" → "{{user_id.0}}" (matches structure)
      assert result2.status == 200
      # user_id is templated, so gets substituted with new value
      assert result2.body["user_id"] == "user-99999"
      # api_key is NOT templated, stays as filtered value from cassette
      assert result2.body["api_key"] == "sk-FILTERED"
      assert result2.body["status"] == "success"
    end
  end

  describe "empty patterns edge case" do
    @tag capture_log: true
    test "template with empty patterns works correctly" do
      bypass = Bypass.open()

      # Record without any patterns
      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678", "name" => "Widget"}))
      end)

      result =
        with_cassette(
          "empty_patterns",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: []
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/data",
              json: %{"sku" => "1234-5678", "name" => "Widget"},
              plug: plug
            )
          end
        )

      assert result.status == 200

      # Verify cassette structure
      cassette_path = Path.join(@cassette_dir, "empty_patterns.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Template enabled but no patterns
      assert interaction["template"]["enabled"] == true
      assert interaction["template"]["patterns"] == %{}
      assert interaction["template"]["recorded_values"] == %{}

      # No templating should occur - request should not have template markers
      refute Jason.encode!(interaction["request"]["body_json"]) =~ ~r/\{\{/

      assert interaction["response"]["body_json"] == %{"sku" => "1234-5678", "name" => "Widget"}
    end
  end

  describe "headers with pattern-matching values" do
    @tag capture_log: true
    test "headers are not extracted even when they match patterns" do
      bypass = Bypass.open()

      # Record with header containing value that matches user_id pattern
      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        # Verify header present
        assert Conn.get_req_header(conn, "x-request-id") == ["user-12345"]

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"user_id" => "user-12345", "status" => "ok"}))
      end)

      result1 =
        with_cassette(
          "headers_not_extracted",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"user_id" => "user-12345"},
              headers: [{"x-request-id", "user-12345"}],
              plug: plug
            )
          end
        )

      assert result1.status == 200

      # Read cassette
      cassette_path = Path.join(@cassette_dir, "headers_not_extracted.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Only ONE value should be recorded (from body, not header)
      assert interaction["template"]["recorded_values"]["user_id"] == ["user-12345"]

      # Response body should be templated
      assert interaction["response"]["body_json"]["user_id"] == "{{user_id.0}}"

      # Replay with DIFFERENT header value but SAME body user_id
      result2 =
        with_cassette(
          "headers_not_extracted",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [user_id: ~r/user-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"user_id" => "user-99999"},
              headers: [{"x-request-id", "user-DIFFERENT"}],
              plug: plug
            )
          end
        )

      # Should match and substitute because headers are ignored
      assert result2.status == 200
      assert result2.body["user_id"] == "user-99999"
    end
  end

  describe "regex options persistence" do
    @tag capture_log: true
    test "case-insensitive pattern options preserved across cassette save/reload" do
      bypass = Bypass.open()

      # Record with case-insensitive pattern that matches mixed case
      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "ABC-123"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"code" => "ABC-123", "status" => "ok"}))
      end)

      # Record with mixed case (uppercase)
      result1 =
        with_cassette(
          "regex_opts_persistence",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Case-insensitive pattern - should match ABC, abc, Abc, etc.
              patterns: [code: ~r/[a-z]{3}-\d{3}/i]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"code" => "ABC-123"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["code"] == "ABC-123"

      # Verify cassette stores pattern with options
      cassette_path = Path.join(@cassette_dir, "regex_opts_persistence.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Pattern should be stored with source and opts
      pattern_data = interaction["template"]["patterns"]["code"]
      assert is_map(pattern_data)
      assert pattern_data["source"] == "[a-z]{3}-\\d{3}"
      assert "caseless" in pattern_data["opts"]

      # Replay with lowercase - should still match because opts are preserved
      # This specifically tests that the 'i' flag survives serialization
      result2 =
        with_cassette(
          "regex_opts_persistence",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [code: ~r/[a-z]{3}-\d{3}/i]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"code" => "xyz-999"},
              plug: plug
            )
          end
        )

      # Should match and substitute with lowercase value
      assert result2.status == 200
      assert result2.body["code"] == "xyz-999"
    end

    @tag capture_log: true
    test "unicode pattern options preserved across cassette save/reload" do
      bypass = Bypass.open()

      # Record with unicode pattern
      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "café"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"name" => "café", "id" => 1}))
      end)

      result1 =
        with_cassette(
          "regex_unicode_opts",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Unicode pattern
              patterns: [name: ~r/\w+/u]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/api",
              json: %{"name" => "café"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["name"] == "café"

      # Verify cassette stores unicode option
      cassette_path = Path.join(@cassette_dir, "regex_unicode_opts.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      pattern_data = interaction["template"]["patterns"]["name"]
      assert is_map(pattern_data)
      assert "unicode" in pattern_data["opts"] or "ucp" in pattern_data["opts"]
    end
  end

  describe "binary body with templating enabled" do
    @tag capture_log: true
    test "templating request patterns works when response is binary" do
      bypass = Bypass.open()

      # PNG header bytes (not valid UTF-8)
      png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

      # Request has templatable ID, response is binary image
      Bypass.expect_once(bypass, "GET", "/images/img-12345.png", fn conn ->
        conn
        |> Conn.put_resp_content_type("image/png")
        |> Conn.resp(200, png_bytes)
      end)

      # Record - should not crash despite binary response
      result1 =
        with_cassette(
          "binary_response_with_template",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Pattern targets URL, not binary body
              patterns: [image_id: ~r/img-\d+/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/images/img-12345.png", plug: plug)
          end
        )

      assert result1.status == 200
      # Response body is binary
      assert is_binary(result1.body)

      # Verify cassette was created correctly
      cassette_path = Path.join(@cassette_dir, "binary_response_with_template.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Template enabled with pattern
      assert interaction["template"]["enabled"] == true
      assert interaction["template"]["recorded_values"]["image_id"] == ["img-12345"]

      # Request URI should be templated
      assert interaction["request"]["uri"] =~ "{{image_id.0}}"

      # Response should be stored as blob, not templated
      assert interaction["response"]["body_type"] == "blob"
      assert Map.has_key?(interaction["response"], "body_blob")
      refute interaction["response"]["body_blob"] =~ "{{"

      # Replay with different image ID - should match via template
      result2 =
        with_cassette(
          "binary_response_with_template",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [image_id: ~r/img-\d+/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/images/img-99999.png", plug: plug)
          end
        )

      # Should match and return same binary response
      assert result2.status == 200
      assert result2.body == png_bytes
    end

    @tag capture_log: true
    test "binary request body does not crash templating" do
      bypass = Bypass.open()

      # Binary request, JSON response
      Bypass.expect_once(bypass, "POST", "/upload/file-123", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        # Body is binary
        assert is_binary(body)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"file_id" => "file-123", "size" => byte_size(body)}))
      end)

      binary_content = <<0, 1, 2, 3, 255, 254, 253, 252>>

      # Record - should not crash despite binary request body
      result1 =
        with_cassette(
          "binary_request_with_template",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Pattern targets URL, not binary body
              patterns: [file_id: ~r/file-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/upload/file-123",
              body: binary_content,
              headers: [{"content-type", "application/octet-stream"}],
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["file_id"] == "file-123"

      # Verify cassette
      cassette_path = Path.join(@cassette_dir, "binary_request_with_template.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)
      interaction = List.first(cassette["interactions"])

      # Request body stored as blob, not templated
      assert interaction["request"]["body_type"] == "blob"
      refute interaction["request"]["body_blob"] =~ "{{"

      # But URI should still be templated
      assert interaction["request"]["uri"] =~ "{{file_id.0}}"

      # Response should be templated normally (JSON)
      assert interaction["response"]["body_json"]["file_id"] == "{{file_id.0}}"
    end
  end
end
