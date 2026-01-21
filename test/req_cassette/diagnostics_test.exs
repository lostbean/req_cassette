defmodule ReqCassette.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias ReqCassette.Cassette

  @cassette_dir "test/fixtures/diagnostics"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "diagnose_mismatch/5" do
    test "identifies method mismatch" do
      cassette = build_cassette_with_interaction("GET", "http://localhost/api", "", %{})

      conn = build_conn("POST", "localhost", "/api", "")
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:method, :uri])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:no_match, "GET", "POST"} = results[:method]
      assert {:match, _, _} = results[:uri]
    end

    test "identifies uri mismatch" do
      cassette = build_cassette_with_interaction("GET", "http://localhost/old-path", "", %{})

      conn = build_conn("GET", "localhost", "/new-path", "")
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:method, :uri])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:match, _, _} = results[:method]
      assert {:no_match, "http://localhost/old-path", "http://localhost/new-path"} = results[:uri]
    end

    test "identifies query mismatch" do
      cassette = build_cassette_with_interaction("GET", "http://localhost/api", "a=1", %{})

      conn = build_conn("GET", "localhost", "/api", "b=2")
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:method, :uri, :query])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:match, _, _} = results[:method]
      assert {:match, _, _} = results[:uri]
      assert {:no_match, "a=1", "b=2"} = results[:query]
    end

    test "identifies body mismatch" do
      cassette =
        build_cassette_with_interaction(
          "POST",
          "http://localhost/api",
          "",
          %{},
          ~s({"key":"old"})
        )

      conn = build_conn("POST", "localhost", "/api", "")

      diagnostics =
        Cassette.diagnose_mismatch(cassette, conn, ~s({"key":"new"}), [:method, :body])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:match, _, _} = results[:method]
      assert {:no_match, ~s({"key":"old"}), ~s({"key":"new"})} = results[:body]
    end

    test "diagnoses multiple interactions" do
      cassette =
        %{
          "version" => "1.0",
          "interactions" => [
            build_interaction("GET", "http://localhost/first", "", %{}),
            build_interaction("GET", "http://localhost/second", "", %{})
          ]
        }

      conn = build_conn("GET", "localhost", "/third", "")
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:method, :uri])

      assert length(diagnostics) == 2

      [%{index: 0, results: r1}, %{index: 1, results: r2}] = diagnostics

      assert {:match, _, _} = r1[:method]
      assert {:no_match, "http://localhost/first", "http://localhost/third"} = r1[:uri]

      assert {:match, _, _} = r2[:method]
      assert {:no_match, "http://localhost/second", "http://localhost/third"} = r2[:uri]
    end

    test "all fields match returns match status" do
      cassette = build_cassette_with_interaction("GET", "http://localhost/api", "", %{})

      conn = build_conn("GET", "localhost", "/api", "")
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:method, :uri])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:match, "GET", "GET"} = results[:method]
      assert {:match, "http://localhost/api", "http://localhost/api"} = results[:uri]
    end

    test "identifies headers mismatch" do
      cassette =
        build_cassette_with_interaction("GET", "http://localhost/api", "", %{
          "x-api-key" => ["key1"],
          "content-type" => ["application/json"]
        })

      conn = build_conn_with_headers("GET", "localhost", "/api", "", [{"x-api-key", "key2"}])
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:method, :headers])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:match, _, _} = results[:method]
      assert {:no_match, _, _} = results[:headers]
    end

    test "handles empty cassette gracefully" do
      cassette = Cassette.new()
      conn = build_conn("GET", "localhost", "/api", "")

      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:method, :uri])

      assert diagnostics == []
    end

    test "handles unknown/custom matchers gracefully" do
      cassette = build_cassette_with_interaction("GET", "http://localhost/api", "", %{})

      conn = build_conn("GET", "localhost", "/api", "")
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:method, :unknown_matcher])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:match, "GET", "GET"} = results[:method]
      # Unknown matcher returns match with nil values
      assert {:match, nil, nil} = results[:unknown_matcher]
    end
  end

  describe "format_mismatch_diagnostics/2" do
    test "formats single field mismatch" do
      diagnostics = [
        %{
          index: 0,
          results: %{
            method: {:match, "GET", "GET"},
            uri: {:no_match, "http://localhost/old", "http://localhost/new"}
          }
        }
      ]

      formatted = Cassette.format_mismatch_diagnostics(diagnostics, [:method, :uri])

      assert formatted =~ "🟢 :method match"
      assert formatted =~ "🔴 :uri NO match"
      assert formatted =~ "🔬 :uri details"
      assert formatted =~ "Record 1:"
      assert formatted =~ ~s(stored: "http://localhost/old")
      assert formatted =~ ~s(value:  "http://localhost/new")
    end

    test "formats multiple field mismatches" do
      diagnostics = [
        %{
          index: 0,
          results: %{
            method: {:no_match, "GET", "POST"},
            uri: {:no_match, "http://localhost/old", "http://localhost/new"}
          }
        }
      ]

      formatted = Cassette.format_mismatch_diagnostics(diagnostics, [:method, :uri])

      assert formatted =~ "🔴 :method NO match"
      assert formatted =~ "🔴 :uri NO match"
      assert formatted =~ "🔬 :method details"
      assert formatted =~ "🔬 :uri details"
    end

    test "formats multiple interactions" do
      diagnostics = [
        %{
          index: 0,
          results: %{
            uri: {:no_match, "http://localhost/first", "http://localhost/third"}
          }
        },
        %{
          index: 1,
          results: %{
            uri: {:no_match, "http://localhost/second", "http://localhost/third"}
          }
        }
      ]

      formatted = Cassette.format_mismatch_diagnostics(diagnostics, [:uri])

      assert formatted =~ "Record 1:"
      assert formatted =~ ~s(stored: "http://localhost/first")
      assert formatted =~ "Record 2:"
      assert formatted =~ ~s(stored: "http://localhost/second")
    end

    test "shows match when any interaction matches on a field" do
      # One interaction matches on method, another doesn't
      diagnostics = [
        %{
          index: 0,
          results: %{
            method: {:match, "GET", "GET"},
            uri: {:no_match, "http://localhost/first", "http://localhost/third"}
          }
        },
        %{
          index: 1,
          results: %{
            method: {:no_match, "POST", "GET"},
            uri: {:no_match, "http://localhost/second", "http://localhost/third"}
          }
        }
      ]

      formatted = Cassette.format_mismatch_diagnostics(diagnostics, [:method, :uri])

      # Method shows as match since at least one interaction matched
      assert formatted =~ "🟢 :method match"
      assert formatted =~ "🔴 :uri NO match"
    end

    test "truncates long values" do
      long_body = String.duplicate("x", 300)

      diagnostics = [
        %{
          index: 0,
          results: %{
            body: {:no_match, long_body, "short"}
          }
        }
      ]

      formatted = Cassette.format_mismatch_diagnostics(diagnostics, [:body])

      # Should contain truncation indicator
      assert formatted =~ "..."
      # Should not contain the full long body
      refute formatted =~ long_body
    end
  end

  describe "integration with error message" do
    test "mismatch error includes diagnostic output" do
      import ReqCassette
      alias Plug.Conn

      bypass = Bypass.open()

      # Record a GET request
      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{method: "GET"}))
      end)

      with_cassette("diagnostic_test", [cassette_dir: @cassette_dir], fn plug ->
        Req.get!("http://localhost:#{bypass.port}/api", plug: plug)
      end)

      # Try to replay a POST request (won't match)
      error =
        assert_raise RuntimeError, fn ->
          with_cassette(
            "diagnostic_test",
            [cassette_dir: @cassette_dir, mode: :replay],
            fn plug ->
              Req.post!("http://localhost:#{bypass.port}/api", plug: plug)
            end
          )
        end

      # Verify diagnostic output is included
      assert error.message =~ "No matching interaction found"
      assert error.message =~ "🔴 :method NO match"
      assert error.message =~ "🔬 :method details"
      assert error.message =~ "Record 1:"
      assert error.message =~ ~s(stored: "GET")
      assert error.message =~ ~s(value:  "POST")
    end
  end

  describe "filter options in diagnostics" do
    test "applies filter_sensitive_data during query diagnosis" do
      # Cassette has redacted query
      cassette =
        build_cassette_with_interaction("GET", "http://localhost/api", "key=<REDACTED>", %{})

      # Incoming request has actual secret
      conn = build_conn("GET", "localhost", "/api", "key=secret123")

      # With filter that normalizes the incoming query
      filter_opts = %{filter_sensitive_data: [{~r/key=[\w]+/, "key=<REDACTED>"}]}
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:query], filter_opts)

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      # Should match because filter normalizes the incoming query to match stored
      assert {:match, "key=<REDACTED>", "key=<REDACTED>"} = results[:query]
    end

    test "applies filter_sensitive_data during uri diagnosis" do
      # Cassette has redacted URI
      cassette =
        build_cassette_with_interaction("GET", "http://localhost/api/user_<ID>/profile", "", %{})

      # Incoming request has actual user ID
      conn = build_conn("GET", "localhost", "/api/user_12345/profile", "")

      # With filter that normalizes user IDs
      filter_opts = %{filter_sensitive_data: [{~r/user_\d+/, "user_<ID>"}]}
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:uri], filter_opts)

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      # Should match because filter normalizes the incoming URI
      assert {:match, _, _} = results[:uri]
    end

    test "applies filter_request_headers during headers diagnosis" do
      # Cassette has no authorization header (it was filtered during recording)
      cassette =
        build_cassette_with_interaction("GET", "http://localhost/api", "", %{
          "content-type" => ["application/json"]
        })

      # Incoming request has authorization header
      conn =
        build_conn_with_headers("GET", "localhost", "/api", "", [
          {"authorization", "Bearer secret"},
          {"content-type", "application/json"}
        ])

      # With filter that removes authorization header
      filter_opts = %{filter_request_headers: ["authorization"]}
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "", [:headers], filter_opts)

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      # Should match because filter removes authorization from incoming headers
      assert {:match, _, _} = results[:headers]
    end

    test "applies filter_sensitive_data during body diagnosis" do
      # Cassette has redacted body
      cassette =
        build_cassette_with_interaction(
          "POST",
          "http://localhost/api",
          "",
          %{"content-type" => ["application/json"]},
          ~s({"password":"<REDACTED>","user":"alice"})
        )

      # Incoming request has actual password
      conn =
        build_conn_with_headers("POST", "localhost", "/api", "", [
          {"content-type", "application/json"}
        ])

      # With filter that redacts passwords
      filter_opts = %{
        filter_sensitive_data: [{~r/"password":"[^"]+"/, ~s("password":"<REDACTED>")}]
      }

      diagnostics =
        Cassette.diagnose_mismatch(
          cassette,
          conn,
          ~s({"password":"secret123","user":"alice"}),
          [:body],
          filter_opts
        )

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      # Should match because filter normalizes the incoming body
      assert {:match, _, _} = results[:body]
    end
  end

  describe "blob body diagnostics" do
    test "identifies blob body mismatch" do
      # Build cassette with blob body
      blob_body = Base.encode64("binary data 1")

      cassette = %{
        "version" => "1.0",
        "interactions" => [
          %{
            "request" => %{
              "method" => "POST",
              "uri" => "http://localhost/upload",
              "query_string" => "",
              "headers" => %{"content-type" => ["application/octet-stream"]},
              "body_type" => "blob",
              "body_blob" => blob_body
            },
            "response" => %{
              "status" => 200,
              "headers" => %{},
              "body_type" => "text",
              "body" => ""
            },
            "recorded_at" => "2025-01-01T00:00:00Z"
          }
        ]
      }

      conn =
        build_conn_with_headers("POST", "localhost", "/upload", "", [
          {"content-type", "application/octet-stream"}
        ])

      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "binary data 2", [:method, :body])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:match, _, _} = results[:method]
      assert {:no_match, _, _} = results[:body]
    end

    test "identifies blob body match" do
      blob_body = Base.encode64("same binary data")

      cassette = %{
        "version" => "1.0",
        "interactions" => [
          %{
            "request" => %{
              "method" => "POST",
              "uri" => "http://localhost/upload",
              "query_string" => "",
              "headers" => %{"content-type" => ["application/octet-stream"]},
              "body_type" => "blob",
              "body_blob" => blob_body
            },
            "response" => %{
              "status" => 200,
              "headers" => %{},
              "body_type" => "text",
              "body" => ""
            },
            "recorded_at" => "2025-01-01T00:00:00Z"
          }
        ]
      }

      conn =
        build_conn_with_headers("POST", "localhost", "/upload", "", [
          {"content-type", "application/octet-stream"}
        ])

      diagnostics = Cassette.diagnose_mismatch(cassette, conn, "same binary data", [:body])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:match, _, _} = results[:body]
    end
  end

  describe "JSON body normalization in diagnostics" do
    test "JSON bodies with different key order match" do
      # Cassette has JSON with keys in one order
      cassette =
        build_cassette_with_interaction(
          "POST",
          "http://localhost/api",
          "",
          %{"content-type" => ["application/json"]},
          ~s({"a":1,"b":2})
        )

      conn =
        build_conn_with_headers("POST", "localhost", "/api", "", [
          {"content-type", "application/json"}
        ])

      # Incoming request has same JSON but different key order
      diagnostics = Cassette.diagnose_mismatch(cassette, conn, ~s({"b":2,"a":1}), [:body])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      # Should match because JSON is normalized
      assert {:match, _, _} = results[:body]
    end

    test "JSON bodies with different values don't match" do
      cassette =
        build_cassette_with_interaction(
          "POST",
          "http://localhost/api",
          "",
          %{"content-type" => ["application/json"]},
          ~s({"key":"value1"})
        )

      conn =
        build_conn_with_headers("POST", "localhost", "/api", "", [
          {"content-type", "application/json"}
        ])

      diagnostics = Cassette.diagnose_mismatch(cassette, conn, ~s({"key":"value2"}), [:body])

      assert length(diagnostics) == 1
      [%{index: 0, results: results}] = diagnostics

      assert {:no_match, _, _} = results[:body]
    end
  end

  # Helper functions

  defp build_conn(method, host, path, query_string) do
    %Plug.Conn{
      method: method,
      scheme: :http,
      host: host,
      port: 80,
      request_path: path,
      query_string: query_string,
      req_headers: []
    }
  end

  defp build_conn_with_headers(method, host, path, query_string, headers) do
    %Plug.Conn{
      method: method,
      scheme: :http,
      host: host,
      port: 80,
      request_path: path,
      query_string: query_string,
      req_headers: headers
    }
  end

  defp build_cassette_with_interaction(method, uri, query_string, headers, body \\ "") do
    %{
      "version" => "1.0",
      "interactions" => [
        build_interaction(method, uri, query_string, headers, body)
      ]
    }
  end

  defp build_interaction(method, uri, query_string, headers, body \\ "") do
    {body_type, body_field, body_value} =
      cond do
        body == "" ->
          {"text", "body", ""}

        String.starts_with?(body, "{") or String.starts_with?(body, "[") ->
          case Jason.decode(body) do
            {:ok, decoded} -> {"json", "body_json", decoded}
            {:error, _} -> {"text", "body", body}
          end

        true ->
          {"text", "body", body}
      end

    %{
      "request" => %{
        "method" => method,
        "uri" => uri,
        "query_string" => query_string,
        "headers" => headers,
        "body_type" => body_type,
        body_field => body_value
      },
      "response" => %{
        "status" => 200,
        "headers" => %{},
        "body_type" => "text",
        "body" => ""
      },
      "recorded_at" => "2025-01-01T00:00:00Z"
    }
  end
end
