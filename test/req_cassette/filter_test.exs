defmodule ReqCassette.FilterTest do
  use ExUnit.Case, async: true

  import ReqCassette

  alias Plug.Conn

  @cassette_dir "test/fixtures/filter"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "filter_sensitive_data" do
    test "filters API keys from request body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/auth", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: "ok"}))
      end)

      # Make request with API key
      with_cassette(
        "auth",
        [
          cassette_dir: @cassette_dir,
          filter_sensitive_data: [
            {~r/api_key=[\w-]+/, "api_key=<REDACTED>"}
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/auth?api_key=secret123",
            plug: plug
          )
        end
      )

      # Verify cassette was created and API key is redacted
      cassette_path = Path.join(@cassette_dir, "auth.json")
      {:ok, data} = File.read(cassette_path)

      refute String.contains?(data, "secret123")
      assert String.contains?(data, "api_key=<REDACTED>")
    end

    test "filters tokens from JSON response body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/login", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{token: "super-secret-token-123"}))
      end)

      # Make request
      with_cassette(
        "login",
        [
          cassette_dir: @cassette_dir,
          filter_sensitive_data: [
            {~r/"token":"[^"]+"/, ~s("token":"<REDACTED>")}
          ]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/login", plug: plug)
        end
      )

      # Verify token is redacted in cassette
      cassette_path = Path.join(@cassette_dir, "login.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      refute String.contains?(data, "super-secret-token-123")
      # Check that the token value in the JSON is redacted
      assert get_in(cassette, ["interactions", Access.at(0), "response", "body_json", "token"]) ==
               "<REDACTED>"
    end

    test "applies multiple regex filters" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            request_received: body,
            api_key: "response-key-456",
            token: "response-token-789"
          })
        )
      end)

      # Make request with multiple sensitive values
      with_cassette(
        "multi_filter",
        [
          cassette_dir: @cassette_dir,
          filter_sensitive_data: [
            # Match keys in query string
            {~r/api_key=[\w-]+/, "api_key=<REDACTED>"},
            {~r/token=[\w-]+/, "token=<REDACTED>"},
            # Match values in JSON (both patterns to cover all bases)
            {~r/response-key-456/, "<REDACTED>"},
            {~r/response-token-789/, "<REDACTED>"}
          ]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/api?api_key=request-key-123&token=request-token-456",
            plug: plug
          )
        end
      )

      # Verify both are redacted
      cassette_path = Path.join(@cassette_dir, "multi_filter.json")
      {:ok, data} = File.read(cassette_path)

      # Check query string redaction
      refute String.contains?(data, "request-key-123")
      refute String.contains?(data, "request-token-456")
      assert String.contains?(data, "api_key=<REDACTED>")
      assert String.contains?(data, "token=<REDACTED>")

      # Check response body redaction
      refute String.contains?(data, "response-key-456")
      refute String.contains?(data, "response-token-789")
    end
  end

  describe "filter_request_headers" do
    test "removes specified request headers" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{data: "ok"}))
      end)

      # Make request with authorization header
      with_cassette(
        "filtered_headers",
        [
          cassette_dir: @cassette_dir,
          filter_request_headers: ["authorization", "x-api-key"]
        ],
        fn plug ->
          Req.get!(
            "http://localhost:#{bypass.port}/api",
            headers: [
              {"authorization", "Bearer secret-token"},
              {"x-api-key", "my-api-key"},
              {"user-agent", "req/0.5.15"}
            ],
            plug: plug
          )
        end
      )

      # Verify headers are removed from cassette
      cassette_path = Path.join(@cassette_dir, "filtered_headers.json")
      {:ok, data} = File.read(cassette_path)

      refute String.contains?(data, "Bearer secret-token")
      refute String.contains?(data, "my-api-key")
      assert String.contains?(data, "user-agent")
    end

    test "header filtering is case-insensitive" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{data: "ok"}))
      end)

      # Make request with Authorization (capitalized)
      with_cassette(
        "case_insensitive",
        [
          cassette_dir: @cassette_dir,
          filter_request_headers: ["authorization"]
        ],
        fn plug ->
          Req.get!(
            "http://localhost:#{bypass.port}/api",
            headers: [{"Authorization", "Bearer token"}],
            plug: plug
          )
        end
      )

      # Verify header is removed regardless of case
      cassette_path = Path.join(@cassette_dir, "case_insensitive.json")
      {:ok, data} = File.read(cassette_path)

      refute String.contains?(data, "Bearer token")
    end
  end

  describe "filter_response_headers" do
    test "removes specified response headers" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_header("set-cookie", "session=abc123; HttpOnly")
        |> Conn.put_resp_header("x-secret", "secret-value")
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{data: "ok"}))
      end)

      # Make request
      with_cassette(
        "filtered_response_headers",
        [
          cassette_dir: @cassette_dir,
          filter_response_headers: ["set-cookie", "x-secret"]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/api", plug: plug)
        end
      )

      # Verify response headers are removed
      cassette_path = Path.join(@cassette_dir, "filtered_response_headers.json")
      {:ok, data} = File.read(cassette_path)

      refute String.contains?(data, "session=abc123")
      refute String.contains?(data, "secret-value")
      assert String.contains?(data, "content-type")
    end
  end

  describe "before_record callback" do
    test "applies custom filtering logic" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/users", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        user = Jason.decode!(body)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            id: 1,
            email: user["email"],
            password: "hashed-password"
          })
        )
      end)

      # Make request with callback to redact email
      redact_email = fn interaction ->
        interaction
        |> update_in(["request", "body_json", "email"], fn _ -> "redacted@example.com" end)
        |> update_in(["response", "body_json", "email"], fn _ -> "redacted@example.com" end)
        |> update_in(["response", "body_json", "password"], fn _ -> "<REDACTED>" end)
      end

      with_cassette(
        "callback_filter",
        [
          cassette_dir: @cassette_dir,
          before_record: redact_email
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/users",
            json: %{email: "alice@example.com", password: "secret123"},
            plug: plug
          )
        end
      )

      # Verify callback was applied
      cassette_path = Path.join(@cassette_dir, "callback_filter.json")
      {:ok, data} = File.read(cassette_path)

      refute String.contains?(data, "alice@example.com")
      assert String.contains?(data, "redacted@example.com")
      refute String.contains?(data, "hashed-password")
      assert String.contains?(data, "<REDACTED>")
    end
  end

  describe "combined filters" do
    test "applies all filter types together" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/complete", fn conn ->
        conn
        |> Conn.put_resp_header("set-cookie", "session=xyz")
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            status: "success",
            api_key: "response-api-key"
          })
        )
      end)

      # Apply all filter types
      with_cassette(
        "combined",
        [
          cassette_dir: @cassette_dir,
          filter_sensitive_data: [
            {~r/api_key=[\w-]+/, "api_key=<REDACTED>"},
            {~r/response-api-key/, "<REDACTED>"}
          ],
          filter_request_headers: ["authorization"],
          filter_response_headers: ["set-cookie"],
          before_record: fn interaction ->
            put_in(interaction, ["response", "body_json", "status"], "filtered")
          end
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/complete?api_key=secret",
            headers: [{"authorization", "Bearer token"}],
            plug: plug
          )
        end
      )

      # Verify all filters were applied
      cassette_path = Path.join(@cassette_dir, "combined.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      # Regex filter - query string
      refute String.contains?(data, "secret")
      assert String.contains?(data, "api_key=<REDACTED>")

      # Regex filter - response body
      refute String.contains?(data, "response-api-key")

      # Request header filter
      refute String.contains?(data, "Bearer token")

      # Response header filter
      refute String.contains?(data, "session=xyz")

      # Callback
      assert get_in(cassette, ["interactions", Access.at(0), "response", "body_json", "status"]) ==
               "filtered"
    end
  end

  describe "binary body filtering" do
    test "filters blob bodies with regex patterns" do
      bypass = Bypass.open()

      # Create binary data with a "secret" pattern
      binary_data = "Binary data with secret_pattern_12345 embedded inside"

      Bypass.expect_once(bypass, "GET", "/image", fn conn ->
        conn
        |> Conn.put_resp_content_type("image/png")
        |> Conn.resp(200, binary_data)
      end)

      # Record with filter on binary body
      with_cassette(
        "blob_filter",
        [
          cassette_dir: @cassette_dir,
          filter_sensitive_data: [
            {~r/secret_pattern_\d+/, "REDACTED"}
          ]
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/image", plug: plug)
        end
      )

      # Verify the blob was decoded, filtered, and re-encoded correctly
      cassette_path = Path.join(@cassette_dir, "blob_filter.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      interaction = hd(cassette["interactions"])
      response = interaction["response"]

      # Should be stored as blob
      assert response["body_type"] == "blob"
      assert response["body_blob"]

      # Decode the blob and verify the filter was applied
      decoded_blob = Base.decode64!(response["body_blob"])
      assert decoded_blob =~ "REDACTED"
      refute decoded_blob =~ "secret_pattern_12345"
      # Ensure the rest of the data is intact
      assert decoded_blob =~ "Binary data with"
      assert decoded_blob =~ "embedded inside"
    end
  end

  describe "replay after filtering" do
    test "replay works after filtering request headers" do
      bypass = Bypass.open()

      # Record phase - expect network call
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{data: "ok"}))
      end)

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_request_headers: ["authorization", "x-api-key"]
      ]

      # First call with auth header - records to cassette
      response1 =
        with_cassette(
          "filtered_replay",
          cassette_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api",
              headers: [{"authorization", "Bearer secret123"}],
              plug: plug
            )
          end
        )

      assert response1.status == 200
      assert response1.body["data"] == "ok"

      # Verify cassette was created without authorization header
      cassette_path = Path.join(@cassette_dir, "filtered_replay.json")
      {:ok, data} = File.read(cassette_path)
      refute String.contains?(data, "authorization")
      refute String.contains?(data, "secret123")

      # Shut down bypass to ensure no network call on replay
      Bypass.down(bypass)

      # Second call with same auth header - should replay from cassette
      response2 =
        with_cassette(
          "filtered_replay",
          cassette_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api",
              headers: [{"authorization", "Bearer secret123"}],
              plug: plug
            )
          end
        )

      # Should get same response from cassette
      assert response2.status == 200
      assert response2.body["data"] == "ok"

      # Third call with strict replay mode - ensures filtering works in CI
      replay_opts = Keyword.put(cassette_opts, :mode, :replay)

      response3 =
        with_cassette(
          "filtered_replay",
          replay_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api",
              headers: [{"authorization", "Bearer secret123"}],
              plug: plug
            )
          end
        )

      # Should get same response from cassette even in strict replay mode
      assert response3.status == 200
      assert response3.body["data"] == "ok"
    end

    test "replay works with regex filters on query params" do
      bypass = Bypass.open()

      # Record phase
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{result: "success"}))
      end)

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_sensitive_data: [
          {~r/api_key=[\w-]+/, "api_key=<REDACTED>"}
        ]
      ]

      # First call with API key in query string
      response1 =
        with_cassette(
          "regex_replay",
          cassette_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api?api_key=secret123",
              plug: plug
            )
          end
        )

      assert response1.status == 200
      assert response1.body["result"] == "success"

      # Verify cassette was created with redacted API key
      cassette_path = Path.join(@cassette_dir, "regex_replay.json")
      {:ok, data} = File.read(cassette_path)
      refute String.contains?(data, "secret123")
      assert String.contains?(data, "api_key=<REDACTED>")

      # Shut down bypass
      Bypass.down(bypass)

      # Second call with same API key - should replay from cassette
      response2 =
        with_cassette(
          "regex_replay",
          cassette_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api?api_key=secret123",
              plug: plug
            )
          end
        )

      # Should get same response from cassette
      assert response2.status == 200
      assert response2.body["result"] == "success"

      # Third call with strict replay mode - ensures filtering works in CI
      replay_opts = Keyword.put(cassette_opts, :mode, :replay)

      response3 =
        with_cassette(
          "regex_replay",
          replay_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api?api_key=secret123",
              plug: plug
            )
          end
        )

      # Should get same response from cassette even in strict replay mode
      assert response3.status == 200
      assert response3.body["result"] == "success"
    end

    test "replay works with combined filters" do
      bypass = Bypass.open()

      # Record phase
      Bypass.expect(bypass, "POST", "/complete", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: "ok"}))
      end)

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_sensitive_data: [
          {~r/token=[\w-]+/, "token=<REDACTED>"}
        ],
        filter_request_headers: ["authorization", "x-api-key"]
      ]

      # First call with both filters applied
      response1 =
        with_cassette(
          "combined_replay",
          cassette_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/complete?token=secret456",
              headers: [
                {"authorization", "Bearer xyz"},
                {"x-api-key", "key123"}
              ],
              plug: plug
            )
          end
        )

      assert response1.status == 200

      # Verify cassette was created with filters applied
      cassette_path = Path.join(@cassette_dir, "combined_replay.json")
      {:ok, data} = File.read(cassette_path)
      refute String.contains?(data, "secret456")
      refute String.contains?(data, "Bearer xyz")
      refute String.contains?(data, "key123")

      # Shut down bypass
      Bypass.down(bypass)

      # Second call - should replay from cassette despite having filtered values
      response2 =
        with_cassette(
          "combined_replay",
          cassette_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/complete?token=secret456",
              headers: [
                {"authorization", "Bearer xyz"},
                {"x-api-key", "key123"}
              ],
              plug: plug
            )
          end
        )

      # Should get same response from cassette
      assert response2.status == 200
      assert response2.body["status"] == "ok"

      # Third call with strict replay mode - ensures filtering works in CI
      replay_opts = Keyword.put(cassette_opts, :mode, :replay)

      response3 =
        with_cassette(
          "combined_replay",
          replay_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/complete?token=secret456",
              headers: [
                {"authorization", "Bearer xyz"},
                {"x-api-key", "key123"}
              ],
              plug: plug
            )
          end
        )

      # Should get same response from cassette even in strict replay mode
      assert response3.status == 200
      assert response3.body["status"] == "ok"
    end

    test "replay works with regex filters on JSON request body" do
      bypass = Bypass.open()

      # Record phase - server echoes back the request body
      Bypass.expect(bypass, "POST", "/authenticate", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        request_data = Jason.decode!(body)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            authenticated: true,
            user: request_data["username"]
          })
        )
      end)

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_sensitive_data: [
          # Filter password in JSON request body
          {~r/"password":"[^"]+"/, ~s("password":"<REDACTED>")},
          {~r/"api_key":"[^"]+"/, ~s("api_key":"<REDACTED>")}
        ]
      ]

      # First call with sensitive data in request body
      response1 =
        with_cassette(
          "json_body_replay",
          cassette_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/authenticate",
              json: %{
                username: "alice",
                password: "secret123",
                api_key: "key-xyz-789"
              },
              plug: plug
            )
          end
        )

      assert response1.status == 200
      assert response1.body["authenticated"] == true
      assert response1.body["user"] == "alice"

      # Verify cassette was created with filtered request body
      cassette_path = Path.join(@cassette_dir, "json_body_replay.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      refute String.contains?(data, "secret123")
      refute String.contains?(data, "key-xyz-789")

      # Check that values are redacted in the JSON structure
      interaction = hd(cassette["interactions"])
      assert interaction["request"]["body_json"]["password"] == "<REDACTED>"
      assert interaction["request"]["body_json"]["api_key"] == "<REDACTED>"

      # Shut down bypass
      Bypass.down(bypass)

      # Second call with same sensitive data - should replay from cassette
      response2 =
        with_cassette(
          "json_body_replay",
          cassette_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/authenticate",
              json: %{
                username: "alice",
                password: "secret123",
                api_key: "key-xyz-789"
              },
              plug: plug
            )
          end
        )

      # Should get same response from cassette
      assert response2.status == 200
      assert response2.body["authenticated"] == true
      assert response2.body["user"] == "alice"

      # Third call with strict replay mode
      replay_opts = Keyword.put(cassette_opts, :mode, :replay)

      response3 =
        with_cassette(
          "json_body_replay",
          replay_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/authenticate",
              json: %{
                username: "alice",
                password: "secret123",
                api_key: "key-xyz-789"
              },
              plug: plug
            )
          end
        )

      # Should get same response even in strict replay mode
      assert response3.status == 200
      assert response3.body["authenticated"] == true
      assert response3.body["user"] == "alice"
    end

    test "replay works with callback filter modifying request body" do
      bypass = Bypass.open()

      # Record phase
      Bypass.expect(bypass, "POST", "/users", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        user = Jason.decode!(body)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            id: 1,
            email: user["email"],
            phone: user["phone"]
          })
        )
      end)

      # Callback that redacts email and phone in request body
      redact_pii = fn interaction ->
        interaction
        |> update_in(["request", "body_json", "email"], fn _ -> "redacted@example.com" end)
        |> update_in(["request", "body_json", "phone"], fn _ -> "555-0000" end)
        |> update_in(["response", "body_json", "email"], fn _ -> "redacted@example.com" end)
        |> update_in(["response", "body_json", "phone"], fn _ -> "555-0000" end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        before_record: redact_pii,
        # Only match on method and URI, not body
        # This allows the callback to safely modify request body without breaking replay
        match_requests_on: [:method, :uri]
      ]

      # First call with real PII
      response1 =
        with_cassette(
          "callback_replay",
          cassette_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/users",
              json: %{
                email: "alice@example.com",
                phone: "555-1234",
                name: "Alice"
              },
              plug: plug
            )
          end
        )

      assert response1.status == 200
      assert response1.body["id"] == 1

      # Verify cassette was created with redacted PII
      cassette_path = Path.join(@cassette_dir, "callback_replay.json")
      {:ok, data} = File.read(cassette_path)
      refute String.contains?(data, "alice@example.com")
      refute String.contains?(data, "555-1234")
      assert String.contains?(data, "redacted@example.com")
      assert String.contains?(data, "555-0000")

      # Shut down bypass
      Bypass.down(bypass)

      # Second call with same PII - should replay from cassette
      response2 =
        with_cassette(
          "callback_replay",
          cassette_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/users",
              json: %{
                email: "alice@example.com",
                phone: "555-1234",
                name: "Alice"
              },
              plug: plug
            )
          end
        )

      # Should get same response from cassette
      assert response2.status == 200
      assert response2.body["id"] == 1

      # Third call with strict replay mode
      replay_opts = Keyword.put(cassette_opts, :mode, :replay)

      response3 =
        with_cassette(
          "callback_replay",
          replay_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/users",
              json: %{
                email: "alice@example.com",
                phone: "555-1234",
                name: "Alice"
              },
              plug: plug
            )
          end
        )

      # Should get same response even in strict replay mode
      assert response3.status == 200
      assert response3.body["id"] == 1
    end

    test "replay works with regex filters on URI path" do
      bypass = Bypass.open()

      # Record phase - dynamic user ID in path
      Bypass.expect(bypass, "GET", "/api/users/user_12345/profile", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{user_id: "user_12345", name: "Alice"}))
      end)

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_sensitive_data: [
          # Filter user IDs in URI path
          {~r/user_\d+/, "user_<ID>"}
        ]
      ]

      # First call with real user ID in path
      response1 =
        with_cassette(
          "uri_path_replay",
          cassette_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api/users/user_12345/profile",
              plug: plug
            )
          end
        )

      assert response1.status == 200
      assert response1.body["name"] == "Alice"

      # Verify cassette was created with filtered URI
      cassette_path = Path.join(@cassette_dir, "uri_path_replay.json")
      {:ok, data} = File.read(cassette_path)
      refute String.contains?(data, "user_12345")
      assert String.contains?(data, "user_<ID>")

      # Shut down bypass
      Bypass.down(bypass)

      # Second call with same user ID - should replay from cassette
      response2 =
        with_cassette(
          "uri_path_replay",
          cassette_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api/users/user_12345/profile",
              plug: plug
            )
          end
        )

      # Should get same response from cassette
      assert response2.status == 200
      assert response2.body["name"] == "Alice"

      # Third call with strict replay mode
      replay_opts = Keyword.put(cassette_opts, :mode, :replay)

      response3 =
        with_cassette(
          "uri_path_replay",
          replay_opts,
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/api/users/user_12345/profile",
              plug: plug
            )
          end
        )

      # Should get same response even in strict replay mode
      assert response3.status == 200
      assert response3.body["name"] == "Alice"
    end
  end

  describe "filter_request callback" do
    test "filters request-only fields during recording and replay" do
      bypass = Bypass.open()

      # Record phase
      Bypass.expect(bypass, "POST", "/users", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: "created"}))
      end)

      filter_req = fn request ->
        request
        |> update_in(["body_json", "email"], fn _ -> "redacted@example.com" end)
        |> update_in(["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_request: filter_req,
        match_requests_on: [:method, :uri]
      ]

      # First call - records
      response1 =
        with_cassette(
          "filter_request_test",
          cassette_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/users",
              json: %{
                email: "alice@example.com",
                timestamp: "2025-10-18T10:00:00Z",
                name: "Alice"
              },
              plug: plug
            )
          end
        )

      assert response1.status == 200

      # Verify cassette was filtered
      cassette_path = Path.join(@cassette_dir, "filter_request_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      interaction = hd(cassette["interactions"])
      assert interaction["request"]["body_json"]["email"] == "redacted@example.com"
      assert interaction["request"]["body_json"]["timestamp"] == "<NORMALIZED>"
      assert interaction["request"]["body_json"]["name"] == "Alice"

      # Shut down bypass
      Bypass.down(bypass)

      # Second call - should replay
      response2 =
        with_cassette(
          "filter_request_test",
          cassette_opts,
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/users",
              json: %{
                email: "bob@example.com",
                timestamp: "2025-10-18T11:00:00Z",
                name: "Alice"
              },
              plug: plug
            )
          end
        )

      assert response2.status == 200
      assert response2.body["status"] == "created"
    end
  end

  describe "filter_response callback" do
    test "filters response-only fields" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            user: "Alice",
            secret_token: "xyz123",
            internal_id: "abc456"
          })
        )
      end)

      filter_resp = fn response ->
        response
        |> update_in(["body_json", "secret_token"], fn _ -> "<REDACTED>" end)
        |> update_in(["body_json", "internal_id"], fn _ -> "<REDACTED>" end)
      end

      with_cassette(
        "filter_response_test",
        [
          cassette_dir: @cassette_dir,
          filter_response: filter_resp
        ],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/api", plug: plug)
        end
      )

      # Verify cassette has filtered response
      cassette_path = Path.join(@cassette_dir, "filter_response_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      interaction = hd(cassette["interactions"])
      assert interaction["response"]["body_json"]["user"] == "Alice"
      assert interaction["response"]["body_json"]["secret_token"] == "<REDACTED>"
      assert interaction["response"]["body_json"]["internal_id"] == "<REDACTED>"
    end
  end

  describe "combined new and old callbacks" do
    test "applies all callback types in correct order" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/complete", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: "ok", data: "response"}))
      end)

      filter_req = fn request ->
        update_in(request, ["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
      end

      filter_resp = fn response ->
        update_in(response, ["body_json", "data"], fn _ -> "<FILTERED>" end)
      end

      before_record_fn = fn interaction ->
        put_in(interaction, ["recorded_at"], "<OVERRIDE>")
      end

      with_cassette(
        "combined_callbacks_test",
        [
          cassette_dir: @cassette_dir,
          filter_request: filter_req,
          filter_response: filter_resp,
          before_record: before_record_fn,
          match_requests_on: [:method, :uri]
        ],
        fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/complete",
            json: %{timestamp: "2025-10-18T10:00:00Z", value: "test"},
            plug: plug
          )
        end
      )

      # Verify all callbacks were applied in order
      cassette_path = Path.join(@cassette_dir, "combined_callbacks_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      interaction = hd(cassette["interactions"])

      # filter_request was applied
      assert interaction["request"]["body_json"]["timestamp"] == "<NORMALIZED>"
      assert interaction["request"]["body_json"]["value"] == "test"

      # filter_response was applied
      assert interaction["response"]["body_json"]["status"] == "ok"
      assert interaction["response"]["body_json"]["data"] == "<FILTERED>"

      # before_record was applied last
      assert interaction["recorded_at"] == "<OVERRIDE>"
    end
  end

  describe "filter_response replay behavior" do
    test "filter_response is NOT re-applied during replay" do
      bypass = Bypass.open()

      # Record phase - response has original value
      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{secret: "ORIGINAL_SECRET", data: "info"}))
      end)

      filter_resp = fn response ->
        update_in(response, ["body_json", "secret"], fn _ -> "REDACTED_ONCE" end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_response: filter_resp
      ]

      # First call - records with filter applied
      with_cassette("filter_response_replay_test", cassette_opts, fn plug ->
        Req.get!("http://localhost:#{bypass.port}/data", plug: plug)
      end)

      # Verify cassette has filtered value
      cassette_path = Path.join(@cassette_dir, "filter_response_replay_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])
      assert interaction["response"]["body_json"]["secret"] == "REDACTED_ONCE"

      # Shutdown bypass - replay will use cassette
      Bypass.down(bypass)

      # Second call - replays from cassette
      # If filter_response were re-applied, it would change "REDACTED_ONCE" to something else
      # But it should NOT be re-applied, so we should get "REDACTED_ONCE" as-is
      response2 =
        with_cassette("filter_response_replay_test", cassette_opts, fn plug ->
          Req.get!("http://localhost:#{bypass.port}/data", plug: plug)
        end)

      # Verify filter_response was NOT re-applied during replay
      assert response2.body["secret"] == "REDACTED_ONCE"
      assert response2.body["data"] == "info"
    end
  end

  describe "filter_request with body matching" do
    test "replay works when filter_request modifies body and body is used for matching" do
      bypass = Bypass.open()

      # Record phase
      Bypass.expect_once(bypass, "POST", "/events", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: "recorded"}))
      end)

      filter_req = fn request ->
        request
        # Normalize timestamp - idempotent transformation
        |> update_in(["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_request: filter_req,
        # Include body in matching
        match_requests_on: [:method, :uri, :body]
      ]

      # First call - records
      response1 =
        with_cassette("filter_request_body_match_test", cassette_opts, fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/events",
            json: %{event: "login", timestamp: "2025-10-18T10:00:00Z"},
            plug: plug
          )
        end)

      assert response1.status == 200

      # Shutdown bypass
      Bypass.down(bypass)

      # Second call with DIFFERENT timestamp - should still match because filter normalizes it
      response2 =
        with_cassette("filter_request_body_match_test", cassette_opts, fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/events",
            json: %{event: "login", timestamp: "2025-10-18T11:30:00Z"},
            plug: plug
          )
        end)

      # Should successfully replay because both timestamps normalize to "<NORMALIZED>"
      assert response2.status == 200
      assert response2.body["status"] == "recorded"
    end
  end

  describe "filter_request + filter_sensitive_data integration" do
    test "applies both regex and callback filters to request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{result: "ok"}))
      end)

      filter_req = fn request ->
        # Callback filter normalizes timestamp
        update_in(request, ["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_sensitive_data: [
          # Regex filter redacts email
          {~r/"email":"[^"]+"/, ~s("email":"<REDACTED>")}
        ],
        filter_request: filter_req
      ]

      with_cassette("filter_request_regex_test", cassette_opts, fn plug ->
        Req.post!(
          "http://localhost:#{bypass.port}/api",
          json: %{email: "alice@example.com", timestamp: "2025-10-18T10:00:00Z", data: "test"},
          plug: plug
        )
      end)

      # Verify both filters were applied
      cassette_path = Path.join(@cassette_dir, "filter_request_regex_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      # Regex filter applied first
      assert interaction["request"]["body_json"]["email"] == "<REDACTED>"
      # Callback filter applied after
      assert interaction["request"]["body_json"]["timestamp"] == "<NORMALIZED>"
      # Unfiltered field preserved
      assert interaction["request"]["body_json"]["data"] == "test"
    end
  end

  describe "filter_response + filter_sensitive_data integration" do
    test "applies both regex and callback filters to response" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/user", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            user: "Alice",
            api_key: "sk-secret123",
            internal_id: "abc456",
            public_data: "visible"
          })
        )
      end)

      filter_resp = fn response ->
        # Callback filter redacts internal_id
        update_in(response, ["body_json", "internal_id"], fn _ -> "<REDACTED_ID>" end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_sensitive_data: [
          # Regex filter redacts api_key
          {~r/"api_key":"[^"]+"/, ~s("api_key":"<REDACTED_KEY>")}
        ],
        filter_response: filter_resp
      ]

      with_cassette("filter_response_regex_test", cassette_opts, fn plug ->
        Req.get!("http://localhost:#{bypass.port}/user", plug: plug)
      end)

      # Verify both filters were applied
      cassette_path = Path.join(@cassette_dir, "filter_response_regex_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      # Regex filter applied first
      assert interaction["response"]["body_json"]["api_key"] == "<REDACTED_KEY>"
      # Callback filter applied after
      assert interaction["response"]["body_json"]["internal_id"] == "<REDACTED_ID>"
      # Unfiltered fields preserved
      assert interaction["response"]["body_json"]["user"] == "Alice"
      assert interaction["response"]["body_json"]["public_data"] == "visible"
    end
  end

  describe "filter_request + filter_request_headers integration" do
    test "applies both header and callback filters to request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/secure", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{success: true}))
      end)

      filter_req = fn request ->
        update_in(request, ["body_json", "user_id"], fn _ -> "<NORMALIZED_USER>" end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_request_headers: ["authorization", "x-api-key"],
        filter_request: filter_req
      ]

      with_cassette("filter_request_headers_callback_test", cassette_opts, fn plug ->
        Req.post!(
          "http://localhost:#{bypass.port}/secure",
          json: %{user_id: "user_12345", action: "delete"},
          headers: [{"authorization", "Bearer secret"}, {"x-api-key", "key123"}],
          plug: plug
        )
      end)

      # Verify both filters were applied
      cassette_path = Path.join(@cassette_dir, "filter_request_headers_callback_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      # Header filters applied
      refute Map.has_key?(interaction["request"]["headers"], "authorization")
      refute Map.has_key?(interaction["request"]["headers"], "x-api-key")

      # Callback filter applied
      assert interaction["request"]["body_json"]["user_id"] == "<NORMALIZED_USER>"
      assert interaction["request"]["body_json"]["action"] == "delete"
    end
  end

  describe "filter_response + filter_response_headers integration" do
    test "applies both header and callback filters to response" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/login", fn conn ->
        conn
        |> Conn.put_resp_header("set-cookie", "session=abc123")
        |> Conn.put_resp_header("x-internal-token", "token456")
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{session_id: "xyz789", user: "Alice"}))
      end)

      filter_resp = fn response ->
        update_in(response, ["body_json", "session_id"], fn _ -> "<REDACTED_SESSION>" end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_response_headers: ["set-cookie", "x-internal-token"],
        filter_response: filter_resp
      ]

      with_cassette("filter_response_headers_callback_test", cassette_opts, fn plug ->
        Req.get!("http://localhost:#{bypass.port}/login", plug: plug)
      end)

      # Verify both filters were applied
      cassette_path = Path.join(@cassette_dir, "filter_response_headers_callback_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      # Header filters applied
      refute Map.has_key?(interaction["response"]["headers"], "set-cookie")
      refute Map.has_key?(interaction["response"]["headers"], "x-internal-token")

      # Callback filter applied
      assert interaction["response"]["body_json"]["session_id"] == "<REDACTED_SESSION>"
      assert interaction["response"]["body_json"]["user"] == "Alice"
    end
  end

  describe "filter_request with text body" do
    test "filters text request bodies" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        conn
        |> Conn.put_resp_content_type("text/plain")
        |> Conn.resp(200, "OK")
      end)

      filter_req = fn request ->
        # Modify text body
        case request["body_type"] do
          "text" ->
            update_in(request, ["body"], fn body ->
              String.replace(body, "12345", "<REDACTED_ID>")
            end)

          _ ->
            request
        end
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_request: filter_req
      ]

      with_cassette("filter_request_text_body_test", cassette_opts, fn plug ->
        Req.post!(
          "http://localhost:#{bypass.port}/webhook",
          body: "user_id=12345&action=update",
          headers: [{"content-type", "text/plain"}],
          plug: plug
        )
      end)

      # Verify text body was filtered
      cassette_path = Path.join(@cassette_dir, "filter_request_text_body_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      assert interaction["request"]["body_type"] == "text"
      assert interaction["request"]["body"] == "user_id=<REDACTED_ID>&action=update"
    end
  end

  describe "filter_response with text body" do
    test "filters text response bodies" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/report", fn conn ->
        conn
        |> Conn.put_resp_content_type("text/csv")
        |> Conn.resp(
          200,
          "name,email,id\nAlice,alice@example.com,12345\nBob,bob@example.com,67890"
        )
      end)

      filter_resp = fn response ->
        case response["body_type"] do
          "text" ->
            update_in(response, ["body"], fn body ->
              body
              |> String.replace(~r/[\w.+-]+@[\w.-]+\.\w+/, "<REDACTED_EMAIL>")
              |> String.replace(~r/\d{5}/, "<REDACTED_ID>")
            end)

          _ ->
            response
        end
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_response: filter_resp
      ]

      with_cassette("filter_response_text_body_test", cassette_opts, fn plug ->
        Req.get!("http://localhost:#{bypass.port}/report", plug: plug)
      end)

      # Verify text body was filtered
      cassette_path = Path.join(@cassette_dir, "filter_response_text_body_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      assert interaction["response"]["body_type"] == "text"

      assert interaction["response"]["body"] ==
               "name,email,id\nAlice,<REDACTED_EMAIL>,<REDACTED_ID>\nBob,<REDACTED_EMAIL>,<REDACTED_ID>"
    end
  end

  describe "filter_request modifying headers used for matching" do
    test "replay fails when filter_request modifies headers and headers are used for matching" do
      bypass = Bypass.open()

      # Record phase
      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{data: "response"}))
      end)

      # This is a BAD pattern - modifying headers that are used for matching
      filter_req = fn request ->
        put_in(request, ["headers", "x-custom-id"], ["<NORMALIZED>"])
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_request: filter_req,
        # Headers are used for matching
        match_requests_on: [:method, :uri, :headers]
      ]

      # First call - records with normalized header
      with_cassette("filter_request_header_match_test", cassette_opts, fn plug ->
        Req.get!(
          "http://localhost:#{bypass.port}/api",
          headers: [{"x-custom-id", "original-123"}],
          plug: plug
        )
      end)

      # Verify cassette has normalized header
      cassette_path = Path.join(@cassette_dir, "filter_request_header_match_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])
      assert interaction["request"]["headers"]["x-custom-id"] == ["<NORMALIZED>"]

      # Shutdown bypass
      Bypass.down(bypass)

      # Second call with different header value - SHOULD match because filter normalizes it
      response2 =
        with_cassette("filter_request_header_match_test", cassette_opts, fn plug ->
          Req.get!(
            "http://localhost:#{bypass.port}/api",
            headers: [{"x-custom-id", "different-456"}],
            plug: plug
          )
        end)

      # Should successfully replay because both headers normalize to "<NORMALIZED>"
      assert response2.status == 200
      assert response2.body["data"] == "response"
    end
  end

  describe "regex filter producing invalid JSON" do
    test "does not crash when regex replaces entire JSON body with non-JSON text" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: "ok"}))
      end)

      # This is a common pattern that replaces entire JSON body with a placeholder
      # Prior behavior: the Filter module handled this gracefully
      # Bug: plug.ex uses Jason.decode! which crashes on non-JSON
      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_sensitive_data: [
          # Replace entire JSON body with non-JSON text
          {~r/.*/, "[FILTERED]"}
        ]
      ]

      # Should not crash - should gracefully fall back to original body
      result =
        with_cassette("regex_invalid_json", cassette_opts, fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/api",
            json: %{secret: "sensitive_data", api_key: "key123"},
            plug: plug
          )
        end)

      assert result.status == 200
    end

    test "replay works when regex produces invalid JSON in request body" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{result: "success"}))
      end)

      # Filter that replaces JSON structure with non-JSON
      cassette_opts = [
        cassette_dir: @cassette_dir,
        mode: :record,
        filter_sensitive_data: [
          {~r/\{.*\}/, "[REQUEST_BODY_FILTERED]"}
        ],
        # Don't match on body since we're filtering it to non-JSON
        match_requests_on: [:method, :uri]
      ]

      # Record
      response1 =
        with_cassette("regex_invalid_json_replay", cassette_opts, fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/data",
            json: %{user: "alice", password: "secret123"},
            plug: plug
          )
        end)

      assert response1.status == 200

      # Shutdown bypass to force replay
      Bypass.down(bypass)

      # Replay should work
      response2 =
        with_cassette("regex_invalid_json_replay", cassette_opts, fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/data",
            json: %{user: "alice", password: "secret123"},
            plug: plug
          )
        end)

      assert response2.status == 200
      assert response2.body["result"] == "success"
    end

    test "gracefully handles regex that breaks JSON structure in response" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/sensitive", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            data: "public_info",
            secret_token: "sk-very-secret-token-12345",
            internal_id: "internal-abc"
          })
        )
      end)

      # Filter that could potentially break JSON if not handled properly
      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_sensitive_data: [
          # This pattern matches the entire JSON and replaces with non-JSON
          {~r/\{"data".*\}/, "[ENTIRE_RESPONSE_FILTERED]"}
        ]
      ]

      # Should not crash
      result =
        with_cassette("regex_break_response_json", cassette_opts, fn plug ->
          Req.get!("http://localhost:#{bypass.port}/sensitive", plug: plug)
        end)

      assert result.status == 200
    end
  end

  describe "filter_request runs exactly once" do
    test "non-idempotent filter_request is applied exactly once during recording" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: "ok"}))
      end)

      # Non-idempotent filter that appends a suffix
      # If run twice, it would append the suffix twice
      call_count = :counters.new(1, [:atomics])

      filter_req = fn request ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        # Append count to a field - if run twice, would show "value_1_2"
        update_in(request, ["body_json", "marker"], fn val ->
          "#{val}_#{count}"
        end)
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_request: filter_req,
        match_requests_on: [:method, :uri]
      ]

      with_cassette("filter_once_test", cassette_opts, fn plug ->
        Req.post!(
          "http://localhost:#{bypass.port}/api",
          json: %{marker: "value", data: "test"},
          plug: plug
        )
      end)

      # Verify filter was called exactly once
      assert :counters.get(call_count, 1) == 1

      # Verify cassette has marker with single suffix (not double)
      cassette_path = Path.join(@cassette_dir, "filter_once_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      # Should be "value_1", NOT "value_1_2" (which would indicate double application)
      assert interaction["request"]["body_json"]["marker"] == "value_1"
    end

    test "non-idempotent regex filter is applied exactly once to request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{result: "success"}))
      end)

      # Regex that appends [FILTERED] - if run twice would produce [FILTERED][FILTERED]
      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_sensitive_data: [
          {~r/(secret_value)/, "\\1[FILTERED]"}
        ],
        match_requests_on: [:method, :uri]
      ]

      with_cassette("regex_once_test", cassette_opts, fn plug ->
        Req.post!(
          "http://localhost:#{bypass.port}/data",
          json: %{password: "secret_value", user: "alice"},
          plug: plug
        )
      end)

      # Verify cassette has single [FILTERED] suffix, not double
      cassette_path = Path.join(@cassette_dir, "regex_once_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      # Should be "secret_value[FILTERED]", NOT "secret_value[FILTERED][FILTERED]"
      assert interaction["request"]["body_json"]["password"] == "secret_value[FILTERED]"
    end

    test "filter_request that deletes a key does not crash on second pass" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/submit", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{submitted: true}))
      end)

      # Filter that deletes a key - would crash or behave unexpectedly if run twice
      filter_req = fn request ->
        {_deleted, updated} = pop_in(request, ["body_json", "to_delete"])
        updated
      end

      cassette_opts = [
        cassette_dir: @cassette_dir,
        filter_request: filter_req,
        match_requests_on: [:method, :uri]
      ]

      # Should not crash
      result =
        with_cassette("filter_delete_key_test", cassette_opts, fn plug ->
          Req.post!(
            "http://localhost:#{bypass.port}/submit",
            json: %{to_delete: "sensitive", keep: "public"},
            plug: plug
          )
        end)

      assert result.status == 200

      # Verify key was deleted
      cassette_path = Path.join(@cassette_dir, "filter_delete_key_test.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interaction = hd(cassette["interactions"])

      refute Map.has_key?(interaction["request"]["body_json"], "to_delete")
      assert interaction["request"]["body_json"]["keep"] == "public"
    end
  end
end
