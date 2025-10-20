defmodule ReqCassette.Template.MatcherTest do
  use ExUnit.Case, async: true

  alias ReqCassette.Template.Matcher

  describe "match?/2 - successful matches" do
    test "matches identical simple requests" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => "key=value",
        "body" => ""
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => "key=value",
        "body" => ""
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "matches requests with template markers" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/items/{{sku.0}}",
        "query_string" => "filter={{filter.0}}",
        "body" => ""
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/items/{{sku.0}}",
        "query_string" => "filter={{filter.0}}",
        "body" => ""
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "matches requests with JSON bodies" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "query_string" => "",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "name" => "Widget"
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "query_string" => "",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "name" => "Widget"
        }
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "matches requests with nested JSON" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "{{sku.0}}"},
            %{"sku" => "{{sku.1}}"}
          ]
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "{{sku.0}}"},
            %{"sku" => "{{sku.1}}"}
          ]
        }
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "matches requests with text bodies" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "text",
        "body" => "Get SKU {{sku.0}}"
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "text",
        "body" => "Get SKU {{sku.0}}"
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "matches requests with empty query strings" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => "",
        "body" => ""
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => "",
        "body" => ""
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "matches requests with nil query strings" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "body" => ""
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "body" => ""
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end
  end

  describe "match?/2 - method mismatches" do
    test "returns error for different methods" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api"
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api"
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "method"
      assert diff[:expected] == "GET"
      assert diff[:actual] == "POST"
    end

    test "is case-insensitive for method comparison" do
      # HTTP methods are case-insensitive by spec
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api"
      }

      incoming_request = %{
        "method" => "get",
        "uri" => "http://example.com/api"
      }

      result = Matcher.match?(cassette_request, incoming_request)

      # Should match despite different casing
      assert result == :match
    end
  end

  describe "match?/2 - URI mismatches" do
    test "returns error for different URIs" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api/v1"
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api/v2"
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "uri"
      assert diff[:expected] == "http://example.com/api/v1"
      assert diff[:actual] == "http://example.com/api/v2"
    end

    test "matches URIs with template markers" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/items/{{sku.0}}"
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/items/{{sku.0}}"
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "detects URI mismatch even with same template marker" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/items/{{sku.0}}"
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/products/{{sku.0}}"
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "uri"
    end
  end

  describe "match?/2 - query string mismatches" do
    test "returns error for different query strings" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => "key=value1"
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => "key=value2"
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "query_string"
      assert diff[:expected] == "key=value1"
      assert diff[:actual] == "key=value2"
    end

    test "matches query strings with template markers" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => "sku={{sku.0}}&filter={{filter.0}}"
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => "sku={{sku.0}}&filter={{filter.0}}"
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "treats missing and empty query strings as equivalent" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "query_string" => ""
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api"
        # No query_string field
      }

      # Both should be treated as empty
      assert Matcher.match?(cassette_request, incoming_request) == :match
    end
  end

  describe "match?/2 - body mismatches" do
    test "returns error for different text bodies" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "text",
        "body" => "Get SKU {{sku.0}}"
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "text",
        "body" => "Get Product {{sku.0}}"
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "body"
    end

    test "returns error for different JSON body structures" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "name" => "Widget"
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "description" => "Widget"
        }
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "body"
    end

    test "returns error for different JSON body values" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "count" => 5
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "count" => 10
        }
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "body"
    end

    test "detects nested JSON differences" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "{{sku.0}}"},
            %{"sku" => "{{sku.1}}"}
          ]
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "{{sku.0}}"}
            # Missing second item
          ]
        }
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "body"
    end

    test "matches empty bodies" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "body" => ""
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "body" => ""
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "treats missing and empty bodies as equivalent" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api"
        # No body field
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "body" => ""
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end
  end

  describe "match?/2 - headers are NOT compared" do
    test "matches even with different headers" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "headers" => %{"authorization" => "Bearer token1"}
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "headers" => %{"authorization" => "Bearer token2"}
      }

      # Headers should NOT be compared in template matching
      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "matches when one has headers and other doesn't" do
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api",
        "headers" => %{"authorization" => "Bearer token"}
      }

      incoming_request = %{
        "method" => "GET",
        "uri" => "http://example.com/api"
        # No headers
      }

      # Should still match
      assert Matcher.match?(cassette_request, incoming_request) == :match
    end
  end

  describe "match?/2 - error details" do
    test "provides detailed error for method mismatch" do
      cassette_request = %{"method" => "GET", "uri" => "http://example.com"}
      incoming_request = %{"method" => "POST", "uri" => "http://example.com"}

      {:error, diff} = Matcher.match?(cassette_request, incoming_request)

      assert diff[:field] == "method"
      assert diff[:expected] == "GET"
      assert diff[:actual] == "POST"
    end

    test "provides detailed error for URI mismatch" do
      cassette_request = %{"method" => "GET", "uri" => "http://example.com/v1"}
      incoming_request = %{"method" => "GET", "uri" => "http://example.com/v2"}

      {:error, diff} = Matcher.match?(cassette_request, incoming_request)

      assert diff[:field] == "uri"
      assert diff[:expected] == "http://example.com/v1"
      assert diff[:actual] == "http://example.com/v2"
    end

    test "returns first mismatch encountered" do
      # Method, URI, and body all different
      cassette_request = %{
        "method" => "GET",
        "uri" => "http://example.com/v1",
        "body" => "body1"
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/v2",
        "body" => "body2"
      }

      {:error, diff} = Matcher.match?(cassette_request, incoming_request)

      # Should return first mismatch (method)
      assert diff[:field] == "method"
    end
  end

  describe "match?/2 - complex scenarios" do
    test "matches complete templated request" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/orders",
        "query_string" => "filter={{filter.0}}",
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "{{sku.0}}", "count" => 1},
            %{"sku" => "{{sku.1}}", "count" => 2}
          ],
          "order_id" => "{{order_id.0}}",
          "metadata" => %{
            "source" => "API",
            "timestamp" => "{{timestamp.0}}"
          }
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/orders",
        "query_string" => "filter={{filter.0}}",
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "{{sku.0}}", "count" => 1},
            %{"sku" => "{{sku.1}}", "count" => 2}
          ],
          "order_id" => "{{order_id.0}}",
          "metadata" => %{
            "source" => "API",
            "timestamp" => "{{timestamp.0}}"
          }
        }
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end

    test "detects difference in deeply nested JSON" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "level1" => %{
            "level2" => %{
              "level3" => %{
                "value" => "{{var.0}}"
              }
            }
          }
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "level1" => %{
            "level2" => %{
              "level3" => %{
                "value" => "{{var.1}}"
              }
            }
          }
        }
      }

      result = Matcher.match?(cassette_request, incoming_request)

      assert {:error, diff} = result
      assert diff[:field] == "body"
    end

    test "matches with mixed static and template values" do
      cassette_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "count" => 5,
          "active" => true,
          "name" => "Widget"
        }
      }

      incoming_request = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "count" => 5,
          "active" => true,
          "name" => "Widget"
        }
      }

      assert Matcher.match?(cassette_request, incoming_request) == :match
    end
  end
end
