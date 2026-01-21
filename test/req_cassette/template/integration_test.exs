defmodule ReqCassette.Template.IntegrationTest do
  use ExUnit.Case, async: true

  import ReqCassette

  alias Plug.Conn

  @cassette_dir "test/fixtures/template_integration"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "basic template functionality" do
    @tag capture_log: true
    test "records with template and replays with different values" do
      bypass = Bypass.open()

      # First request - record with SKU 1234-5678
      Bypass.expect_once(bypass, "POST", "/lookup", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        # Verify we received the original SKU
        assert body =~ "1234-5678"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "sku" => "1234-5678",
            "name" => "Widget",
            "count" => 5
          })
        )
      end)

      # Record the interaction with template
      result1 =
        with_cassette(
          "sku_lookup",
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

      assert result1.status == 200
      assert result1.body["sku"] == "1234-5678"
      assert result1.body["name"] == "Widget"

      # Second request - replay with DIFFERENT SKU 9999-8888
      # Server is not hit - replayed from cassette
      result2 =
        with_cassette(
          "sku_lookup",
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

      # The response should have the NEW SKU substituted
      assert result2.status == 200
      assert result2.body["sku"] == "9999-8888"
      assert result2.body["name"] == "Widget"
      assert result2.body["count"] == 5
    end

    @tag capture_log: true
    test "handles multiple template variables" do
      bypass = Bypass.open()

      # Record with two SKUs
      Bypass.expect_once(bypass, "POST", "/compare", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "1111-2222"
        assert body =~ "3333-4444"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "primary" => "1111-2222",
            "secondary" => "3333-4444",
            "comparison" => "SKU 1111-2222 is better than SKU 3333-4444"
          })
        )
      end)

      with_cassette(
        "compare_skus",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/compare",
            body: "Compare SKU 1111-2222 with SKU 3333-4444",
            plug: plug
          )
        end
      )

      # Replay with different SKUs
      result =
        with_cassette(
          "compare_skus",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/compare",
              body: "Compare SKU 5555-6666 with SKU 7777-8888",
              plug: plug
            )
          end
        )

      # All SKUs should be substituted
      assert result.body["primary"] == "5555-6666"
      assert result.body["secondary"] == "7777-8888"
      assert result.body["comparison"] == "SKU 5555-6666 is better than SKU 7777-8888"
    end
  end

  describe "cassette v2.0 format" do
    @tag capture_log: true
    test "saves cassettes in v2.0 format" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => "ABC-123"}))
      end)

      with_cassette(
        "version_test",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [id: ~r/[A-Z]+-\d+/]
          ]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/data", plug: plug)
        end
      )

      # Read the cassette file and verify v2.0 format
      cassette_path = Path.join(@cassette_dir, "version_test.json")
      assert File.exists?(cassette_path)

      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)

      assert cassette["version"] == "2.0"
      assert is_list(cassette["interactions"])
      assert length(cassette["interactions"]) == 1

      interaction = List.first(cassette["interactions"])
      assert interaction["template"]["enabled"] == true
      assert is_map(interaction["template"]["patterns"])
      # Request should contain template markers
      assert is_map(interaction["request"])
    end

    @tag capture_log: true
    test "verifies cassette v2.0 format content in detail" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "1234"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678", "count" => 5}))
      end)

      with_cassette(
        "format_details",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/api",
            body: "Get SKU 1234-5678",
            plug: plug
          )
        end
      )

      # Read and verify detailed structure
      cassette_path = Path.join(@cassette_dir, "format_details.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)

      interaction = List.first(cassette["interactions"])

      # Verify template metadata
      assert interaction["template"]["enabled"] == true

      # Verify patterns are serialized correctly (with source and opts)
      patterns = interaction["template"]["patterns"]
      assert patterns["sku"]["source"] == "\\d{4}-\\d{4}"
      assert patterns["sku"]["opts"] == []

      # Verify recorded_values
      recorded_values = interaction["template"]["recorded_values"]
      assert recorded_values["sku"] == ["1234-5678"]

      # Verify config
      config = interaction["template"]["config"]
      assert config["allow_key_templates"] == false

      # Verify request structure - should have template markers
      assert interaction["request"]["body"] =~ "{{sku.0}}"

      # Verify response is templated
      assert interaction["response"]["body_json"]["sku"] =~ "{{sku.0}}"
      # Non-templated values should remain literal
      assert interaction["response"]["body_json"]["count"] == 5
    end
  end

  describe "before_record hook integration with templates" do
    @tag capture_log: true
    test "preserves custom keys added by before_record callback" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"sku" => "1234-5678"}))
      end)

      with_cassette(
        "before_record_with_template",
        [
          cassette_dir: @cassette_dir,
          template: [
            patterns: [sku: ~r/\d{4}-\d{4}/]
          ],
          before_record: fn interaction ->
            interaction
            |> Map.put("custom_metadata", %{"version" => "1.0", "source" => "test"})
            |> Map.put("tags", ["api", "sku-lookup"])
          end
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/api",
            body: "Get SKU 1234-5678",
            plug: plug
          )
        end
      )

      # Read the cassette file and verify custom keys are preserved
      cassette_path = Path.join(@cassette_dir, "before_record_with_template.json")
      {:ok, cassette_json} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(cassette_json)

      interaction = List.first(cassette["interactions"])

      # Template metadata should be present
      assert interaction["template"]["enabled"] == true
      assert interaction["template"]["patterns"]["sku"]["source"] == "\\d{4}-\\d{4}"

      # Custom keys from before_record should be preserved
      assert interaction["custom_metadata"] == %{"version" => "1.0", "source" => "test"}
      assert interaction["tags"] == ["api", "sku-lookup"]

      # Standard keys should still exist
      assert is_map(interaction["request"])
      assert is_map(interaction["response"])
      assert interaction["recorded_at"]
    end
  end
end
