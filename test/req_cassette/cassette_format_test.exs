defmodule ReqCassette.CassetteFormatTest do
  use ExUnit.Case, async: true

  alias Plug.Conn
  alias ReqCassette.Cassette

  @cassette_dir "test/fixtures/cassette_format"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "v2.0 format" do
    test "creates cassettes with version 2.0" do
      cassette = Cassette.new()

      assert cassette["version"] == "2.0"
      assert cassette["interactions"] == []
    end

    test "saves cassettes as pretty-printed JSON" do
      cassette = Cassette.new()
      path = Path.join(@cassette_dir, "pretty.json")

      Cassette.save(path, cassette)

      {:ok, content} = File.read(path)

      # Verify it's pretty-printed (multi-line with indentation)
      assert String.contains?(content, "\n")
      assert String.contains?(content, "  ")
      assert String.contains?(content, ~s("version": "2.0"))
    end

    test "includes full request metadata in interactions" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Conn.resp(conn, 200, "OK")
      end)

      # Make a request
      response = Req.get!("http://localhost:#{bypass.port}/test?key=value")

      # Build fake conn for testing
      conn = %Plug.Conn{
        method: "GET",
        scheme: :http,
        host: "localhost",
        port: bypass.port,
        request_path: "/test",
        query_string: "key=value",
        req_headers: [{"user-agent", "test"}]
      }

      cassette = Cassette.new()
      cassette = Cassette.add_interaction(cassette, conn, "", response)

      interaction = hd(cassette["interactions"])

      # Verify request details
      assert interaction["request"]["method"] == "GET"
      assert interaction["request"]["uri"] == "http://localhost:#{bypass.port}/test"
      assert interaction["request"]["query_string"] == "key=value"
      assert is_map(interaction["request"]["headers"])

      # Verify response details
      assert interaction["response"]["status"] == 200
      assert is_binary(interaction["response"]["body_type"])

      # Verify timestamp
      assert is_binary(interaction["recorded_at"])
      assert String.contains?(interaction["recorded_at"], "Z")
    end
  end

  describe "v0.1 format migration" do
    test "loads and migrates v0.1 cassettes" do
      # Create a v0.1 format cassette (old format without version field)
      v01_cassette = %{
        "status" => 200,
        "headers" => %{"content-type" => ["application/json"]},
        "body" => ~s({"message":"hello"})
      }

      path = Path.join(@cassette_dir, "v01.json")
      File.write!(path, Jason.encode!(v01_cassette))

      # Load and verify migration
      {:ok, migrated} = Cassette.load(path)

      assert migrated["version"] == "2.0"
      assert is_list(migrated["interactions"])
      assert length(migrated["interactions"]) == 1

      interaction = hd(migrated["interactions"])

      # Verify migrated response
      assert interaction["response"]["status"] == 200
      assert interaction["response"]["headers"]["content-type"] == ["application/json"]

      # Verify migration markers
      assert interaction["request"]["method"] == "UNKNOWN"
      assert interaction["request"]["uri"] == "UNKNOWN"
      assert interaction["recorded_at"] == "MIGRATED_FROM_V0.1"
    end

    test "loads v1.0 cassettes and migrates to v2.0" do
      # Create a proper v1.0 cassette
      v10_cassette = %{
        "version" => "1.0",
        "interactions" => [
          %{
            "request" => %{
              "method" => "GET",
              "uri" => "http://example.com/api",
              "query_string" => "",
              "headers" => %{},
              "body_type" => "text",
              "body" => ""
            },
            "response" => %{
              "status" => 200,
              "headers" => %{},
              "body_type" => "text",
              "body" => "OK"
            },
            "recorded_at" => "2025-10-16T12:00:00Z"
          }
        ]
      }

      path = Path.join(@cassette_dir, "v10.json")
      File.write!(path, Jason.encode!(v10_cassette))

      # Load and verify migration to v2.0
      {:ok, loaded} = Cassette.load(path)

      # Should be migrated to v2.0 in memory
      assert loaded["version"] == "2.0"
      assert length(loaded["interactions"]) == 1

      # Interaction data should be preserved
      interaction = List.first(loaded["interactions"])
      assert interaction["request"]["method"] == "GET"
      assert interaction["request"]["uri"] == "http://example.com/api"
      assert interaction["response"]["status"] == 200
      assert interaction["response"]["body"] == "OK"
    end
  end

  describe "body types" do
    test "stores JSON bodies as native objects" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/json", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{id: 1, name: "Test", tags: ["a", "b"]}))
      end)

      response = Req.get!("http://localhost:#{bypass.port}/json")

      conn = %Plug.Conn{
        method: "GET",
        scheme: :http,
        host: "localhost",
        port: bypass.port,
        request_path: "/json",
        query_string: "",
        req_headers: []
      }

      cassette = Cassette.new()
      cassette = Cassette.add_interaction(cassette, conn, "", response)

      path = Path.join(@cassette_dir, "json_body.json")
      Cassette.save(path, cassette)

      # Load and verify
      {:ok, content} = File.read(path)
      {:ok, parsed} = Jason.decode(content)

      body_json =
        get_in(parsed, ["interactions", Access.at(0), "response", "body_json"])

      assert body_json["id"] == 1
      assert body_json["name"] == "Test"
      assert body_json["tags"] == ["a", "b"]

      # Verify it's not double-encoded
      refute String.contains?(content, "\\\"id\\\"")
    end

    test "stores binary bodies as base64" do
      # Test with binary PNG header
      png_header = <<137, 80, 78, 71, 13, 10, 26, 10>>

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/image", fn conn ->
        conn
        |> Conn.put_resp_content_type("image/png")
        |> Conn.resp(200, png_header)
      end)

      response = Req.get!("http://localhost:#{bypass.port}/image")

      conn = %Plug.Conn{
        method: "GET",
        scheme: :http,
        host: "localhost",
        port: bypass.port,
        request_path: "/image",
        query_string: "",
        req_headers: []
      }

      cassette = Cassette.new()
      cassette = Cassette.add_interaction(cassette, conn, "", response)

      path = Path.join(@cassette_dir, "binary_body.json")
      Cassette.save(path, cassette)

      # Load and verify
      {:ok, content} = File.read(path)
      {:ok, parsed} = Jason.decode(content)

      body_type =
        get_in(parsed, ["interactions", Access.at(0), "response", "body_type"])

      assert body_type == "blob"

      body_blob =
        get_in(parsed, ["interactions", Access.at(0), "response", "body_blob"])

      assert is_binary(body_blob)
      assert Base.decode64!(body_blob) == png_header
    end

    test "stores text bodies as strings" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/html", fn conn ->
        conn
        |> Conn.put_resp_content_type("text/html")
        |> Conn.resp(200, "<html><body>Hello</body></html>")
      end)

      response = Req.get!("http://localhost:#{bypass.port}/html")

      conn = %Plug.Conn{
        method: "GET",
        scheme: :http,
        host: "localhost",
        port: bypass.port,
        request_path: "/html",
        query_string: "",
        req_headers: []
      }

      cassette = Cassette.new()
      cassette = Cassette.add_interaction(cassette, conn, "", response)

      path = Path.join(@cassette_dir, "text_body.json")
      Cassette.save(path, cassette)

      # Load and verify
      {:ok, content} = File.read(path)
      {:ok, parsed} = Jason.decode(content)

      body_type =
        get_in(parsed, ["interactions", Access.at(0), "response", "body_type"])

      assert body_type == "text"

      body = get_in(parsed, ["interactions", Access.at(0), "response", "body"])

      assert body == "<html><body>Hello</body></html>"
    end
  end

  describe "multiple interactions" do
    test "stores multiple interactions in single cassette" do
      bypass = Bypass.open()

      conn1 = %Plug.Conn{
        method: "GET",
        scheme: :http,
        host: "localhost",
        port: bypass.port,
        request_path: "/1",
        query_string: "",
        req_headers: []
      }

      conn2 = %Plug.Conn{
        method: "GET",
        scheme: :http,
        host: "localhost",
        port: bypass.port,
        request_path: "/2",
        query_string: "",
        req_headers: []
      }

      # Create responses
      Bypass.expect(bypass, "GET", "/1", fn conn ->
        Conn.resp(conn, 200, "Response 1")
      end)

      Bypass.expect(bypass, "GET", "/2", fn conn ->
        Conn.resp(conn, 200, "Response 2")
      end)

      response1 = Req.get!("http://localhost:#{bypass.port}/1")
      response2 = Req.get!("http://localhost:#{bypass.port}/2")

      # Build cassette with multiple interactions
      cassette = Cassette.new()
      cassette = Cassette.add_interaction(cassette, conn1, "", response1)
      cassette = Cassette.add_interaction(cassette, conn2, "", response2)

      assert length(cassette["interactions"]) == 2

      # Verify both interactions are distinct
      [int1, int2] = cassette["interactions"]
      assert int1["request"]["uri"] =~ "/1"
      assert int2["request"]["uri"] =~ "/2"
    end
  end

  describe "error handling" do
    test "returns :not_found for missing cassette file" do
      result = Cassette.load(Path.join(@cassette_dir, "nonexistent.json"))
      assert result == :not_found
    end

    test "returns :not_found for invalid JSON" do
      path = Path.join(@cassette_dir, "invalid.json")
      File.write!(path, "not valid json {")

      result = Cassette.load(path)
      assert result == :not_found
    end
  end
end
