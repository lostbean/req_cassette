defmodule ReqCassette.Template.PresetsTest do
  use ExUnit.Case, async: true

  import ReqCassette

  alias Plug.Conn
  alias ReqCassette.Template.Presets

  @cassette_dir "test/fixtures/presets_integration"

  describe "get/1" do
    test "returns Anthropic patterns" do
      assert {:ok, patterns} = Presets.get(:anthropic)
      assert is_list(patterns)
      assert Keyword.keyword?(patterns)

      # Verify expected pattern names
      pattern_names = Keyword.keys(patterns)
      assert :msg_id in pattern_names
      assert :toolu_id in pattern_names
      assert :anthropic_request_id in pattern_names

      # Verify patterns are regexes
      assert Regex.regex?(patterns[:msg_id])
      assert Regex.regex?(patterns[:toolu_id])
      assert Regex.regex?(patterns[:anthropic_request_id])

      # Verify patterns match expected format
      assert Regex.match?(patterns[:msg_id], "msg_01XzW7o3s58J6KauMpLBFtEf")
      assert Regex.match?(patterns[:toolu_id], "toolu_01K6u2Q9D6W7heeVvKAcLcAJ")
      assert Regex.match?(patterns[:anthropic_request_id], "req_01234abcdef")
    end

    test "returns OpenAI patterns" do
      assert {:ok, patterns} = Presets.get(:openai)
      assert is_list(patterns)
      assert Keyword.keyword?(patterns)

      # Verify expected pattern names
      pattern_names = Keyword.keys(patterns)
      assert :chatcmpl_id in pattern_names
      assert :call_id in pattern_names

      # Verify patterns are regexes
      assert Regex.regex?(patterns[:chatcmpl_id])
      assert Regex.regex?(patterns[:call_id])

      # Verify patterns match expected format
      assert Regex.match?(patterns[:chatcmpl_id], "chatcmpl-abc123def456xyz789")
      assert Regex.match?(patterns[:call_id], "call_abc123")
    end

    test "returns common patterns" do
      assert {:ok, patterns} = Presets.get(:common)
      assert is_list(patterns)
      assert Keyword.keyword?(patterns)

      # Verify expected pattern names
      pattern_names = Keyword.keys(patterns)
      assert :uuid in pattern_names
      assert :iso_timestamp in pattern_names

      # Verify patterns are regexes
      assert Regex.regex?(patterns[:uuid])
      assert Regex.regex?(patterns[:iso_timestamp])

      # Verify UUID pattern matches v4 UUIDs (case insensitive)
      assert Regex.match?(patterns[:uuid], "550e8400-e29b-41d4-a716-446655440000")
      assert Regex.match?(patterns[:uuid], "550E8400-E29B-41D4-A716-446655440000")

      # Verify ISO timestamp patterns
      assert Regex.match?(patterns[:iso_timestamp], "2025-01-15T10:30:00Z")
      assert Regex.match?(patterns[:iso_timestamp], "2025-01-15T10:30:00.123Z")
      assert Regex.match?(patterns[:iso_timestamp], "2025-01-15T10:30:00+05:30")
      assert Regex.match?(patterns[:iso_timestamp], "2025-01-15T10:30:00-08:00")
    end

    test "returns combined LLM patterns" do
      assert {:ok, patterns} = Presets.get(:llm)
      assert is_list(patterns)
      assert Keyword.keyword?(patterns)

      # Should include both Anthropic and OpenAI patterns
      pattern_names = Keyword.keys(patterns)

      # Anthropic patterns
      assert :msg_id in pattern_names
      assert :toolu_id in pattern_names
      assert :anthropic_request_id in pattern_names

      # OpenAI patterns
      assert :chatcmpl_id in pattern_names
      assert :call_id in pattern_names
    end

    test "returns error for unknown preset" do
      assert {:error, {:unknown_preset, :nonexistent}} = Presets.get(:nonexistent)
      assert {:error, {:unknown_preset, :invalid}} = Presets.get(:invalid)
    end
  end

  describe "get!/1" do
    test "returns patterns for valid preset" do
      patterns = Presets.get!(:anthropic)
      assert is_list(patterns)
      assert :msg_id in Keyword.keys(patterns)
    end

    test "raises ArgumentError for unknown preset" do
      assert_raise ArgumentError, ~r/Unknown template preset: :nonexistent/, fn ->
        Presets.get!(:nonexistent)
      end
    end

    test "error message includes available presets" do
      error =
        assert_raise ArgumentError, fn ->
          Presets.get!(:bad_preset)
        end

      assert error.message =~ "Available presets:"
      assert error.message =~ ":anthropic"
      assert error.message =~ ":openai"
      assert error.message =~ ":llm"
      assert error.message =~ ":common"
    end
  end

  describe "available/0" do
    test "returns list of all available presets" do
      presets = Presets.available()

      assert is_list(presets)
      assert :anthropic in presets
      assert :openai in presets
      assert :llm in presets
      assert :common in presets
    end

    test "all listed presets are valid" do
      for preset <- Presets.available() do
        assert {:ok, _patterns} = Presets.get(preset)
      end
    end
  end

  describe "pattern accuracy" do
    test "anthropic msg_id pattern matches real IDs" do
      {:ok, patterns} = Presets.get(:anthropic)

      # Real-world examples from Anthropic API
      assert Regex.match?(patterns[:msg_id], "msg_01XzW7o3s58J6KauMpLBFtEf")
      assert Regex.match?(patterns[:msg_id], "msg_abc123")
      assert Regex.match?(patterns[:msg_id], "msg_ABC123xyz")

      # Should not match other formats
      refute Regex.match?(patterns[:msg_id], "message_abc123")
      refute Regex.match?(patterns[:msg_id], "msg-abc123")
    end

    test "anthropic toolu_id pattern matches real IDs" do
      {:ok, patterns} = Presets.get(:anthropic)

      # Real-world examples
      assert Regex.match?(patterns[:toolu_id], "toolu_01K6u2Q9D6W7heeVvKAcLcAJ")
      assert Regex.match?(patterns[:toolu_id], "toolu_abc123")

      # Should not match other formats
      refute Regex.match?(patterns[:toolu_id], "tool_abc123")
      refute Regex.match?(patterns[:toolu_id], "toolu-abc123")
    end

    test "openai chatcmpl_id pattern matches real IDs" do
      {:ok, patterns} = Presets.get(:openai)

      # Real-world examples
      assert Regex.match?(patterns[:chatcmpl_id], "chatcmpl-abc123def456")
      assert Regex.match?(patterns[:chatcmpl_id], "chatcmpl-7qTnT2RXYB8kKb0M3P7D6G")

      # Should not match other formats
      refute Regex.match?(patterns[:chatcmpl_id], "chatcmpl_abc123")
      refute Regex.match?(patterns[:chatcmpl_id], "chat-abc123")
    end

    test "uuid pattern matches standard UUID v4 format" do
      {:ok, patterns} = Presets.get(:common)

      # Valid UUIDs
      assert Regex.match?(patterns[:uuid], "550e8400-e29b-41d4-a716-446655440000")
      assert Regex.match?(patterns[:uuid], "123e4567-e89b-12d3-a456-426614174000")
      # Case insensitive
      assert Regex.match?(patterns[:uuid], "550E8400-E29B-41D4-A716-446655440000")

      # Invalid formats
      refute Regex.match?(patterns[:uuid], "550e8400e29b41d4a716446655440000")
      refute Regex.match?(patterns[:uuid], "not-a-uuid")
    end
  end

  describe "with_cassette preset integration" do
    setup do
      File.rm_rf!(@cassette_dir)
      File.mkdir_p!(@cassette_dir)
      :ok
    end

    @tag capture_log: true
    test "preset: :anthropic works with anthropic-style IDs" do
      bypass = Bypass.open()

      # Simulate Anthropic API response with msg_id and toolu_id
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "msg_01XzW7o3s58J6KauMpLBFtEf",
            "type" => "message",
            "content" => [
              %{"type" => "text", "text" => "Hello!"},
              %{"type" => "tool_use", "id" => "toolu_01K6u2Q9D6W7heeVvKAcLcAJ", "name" => "test"}
            ]
          })
        )
      end)

      # Record with preset
      result1 =
        with_cassette(
          "anthropic_preset_test",
          [
            cassette_dir: @cassette_dir,
            template: [preset: :anthropic]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/v1/messages",
              json: %{"prompt" => "Hello"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["id"] == "msg_01XzW7o3s58J6KauMpLBFtEf"

      # Replay - different request but matches template structure
      result2 =
        with_cassette(
          "anthropic_preset_test",
          [
            cassette_dir: @cassette_dir,
            template: [preset: :anthropic]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/v1/messages",
              json: %{"prompt" => "Hello"},
              plug: plug
            )
          end
        )

      # Should get same response (replayed)
      assert result2.status == 200
      assert result2.body["id"] == "msg_01XzW7o3s58J6KauMpLBFtEf"
    end

    @tag capture_log: true
    test "preset: :common works with UUIDs" do
      bypass = Bypass.open()

      uuid1 = "550e8400-e29b-41d4-a716-446655440000"
      uuid2 = "123e4567-e89b-12d3-a456-426614174000"

      Bypass.expect_once(bypass, "GET", "/users/#{uuid1}", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{"id" => uuid1, "name" => "Alice"}))
      end)

      # Record with common preset
      result1 =
        with_cassette(
          "uuid_preset_test",
          [
            cassette_dir: @cassette_dir,
            template: [preset: :common]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/users/#{uuid1}",
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["id"] == uuid1

      # Replay with DIFFERENT UUID - template substitution should work
      result2 =
        with_cassette(
          "uuid_preset_test",
          [
            cassette_dir: @cassette_dir,
            template: [preset: :common]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/users/#{uuid2}",
              plug: plug
            )
          end
        )

      # Response should have the NEW UUID substituted
      assert result2.status == 200
      assert result2.body["id"] == uuid2
    end

    @tag capture_log: true
    test "preset combined with custom patterns" do
      bypass = Bypass.open()

      uuid = "550e8400-e29b-41d4-a716-446655440000"

      Bypass.expect_once(bypass, "POST", "/orders", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "id" => uuid,
            "order_ref" => "ORD-12345",
            "status" => "created"
          })
        )
      end)

      # Record with preset + custom pattern
      result1 =
        with_cassette(
          "combined_preset_test",
          [
            cassette_dir: @cassette_dir,
            template: [
              preset: :common,
              patterns: [order_ref: ~r/ORD-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/orders",
              json: %{"order_ref" => "ORD-12345"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["id"] == uuid
      assert result1.body["order_ref"] == "ORD-12345"

      # Replay with different order ref - both UUID and order_ref should be templated
      result2 =
        with_cassette(
          "combined_preset_test",
          [
            cassette_dir: @cassette_dir,
            template: [
              preset: :common,
              patterns: [order_ref: ~r/ORD-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/orders",
              json: %{"order_ref" => "ORD-99999"},
              plug: plug
            )
          end
        )

      assert result2.status == 200
      # Response should have the NEW order_ref substituted
      assert result2.body["order_ref"] == "ORD-99999"
    end

    test "raises error for unknown preset" do
      assert_raise ArgumentError, ~r/Unknown template preset: :nonexistent/, fn ->
        with_cassette(
          "bad_preset_test",
          [
            cassette_dir: @cassette_dir,
            template: [preset: :nonexistent]
          ],
          fn _plug -> :ok end
        )
      end
    end

    test "raises error when template has neither preset nor patterns key" do
      assert_raise ArgumentError, ~r/Template requires either :preset or :patterns/, fn ->
        with_cassette(
          "empty_template_test",
          [
            cassette_dir: @cassette_dir,
            # Empty template options (no preset, no patterns key at all)
            template: []
          ],
          fn _plug -> :ok end
        )
      end
    end

    @tag capture_log: true
    test "allows explicit empty patterns (patterns: [])" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Conn.resp(conn, 200, "ok")
      end)

      # Should NOT raise - explicit patterns: [] is allowed
      result =
        with_cassette(
          "empty_patterns_test",
          [
            cassette_dir: @cassette_dir,
            template: [patterns: []]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/test", plug: plug)
          end
        )

      assert result.status == 200
    end
  end
end
