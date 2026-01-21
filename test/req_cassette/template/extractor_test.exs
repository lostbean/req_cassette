defmodule ReqCassette.Template.ExtractorTest do
  use ExUnit.Case, async: true

  alias ReqCassette.Template.Extractor

  describe "extract_from_string/2" do
    test "extracts single pattern with single match" do
      patterns = %{sku: ~r/\d{4}-\d{4}/}
      string = "SKU 1234-5678"

      result = Extractor.extract_from_string(string, patterns)

      assert result == %{sku: ["1234-5678"]}
    end

    test "extracts single pattern with multiple matches" do
      patterns = %{sku: ~r/\d{4}-\d{4}/}
      string = "SKU 1234-5678 and SKU 5678-9012"

      result = Extractor.extract_from_string(string, patterns)

      assert result == %{sku: ["1234-5678", "5678-9012"]}
    end

    test "extracts multiple different patterns" do
      patterns = %{
        sku: ~r/\d{4}-\d{4}/,
        order_id: ~r/ORD-\d+/
      }

      string = "Order ORD-123 for SKU 1234-5678"

      result = Extractor.extract_from_string(string, patterns)

      assert result == %{
               sku: ["1234-5678"],
               order_id: ["ORD-123"]
             }
    end

    test "returns empty map when no matches found" do
      patterns = %{sku: ~r/\d{4}-\d{4}/}
      string = "No SKU here"

      result = Extractor.extract_from_string(string, patterns)

      assert result == %{}
    end

    test "filters out empty matches" do
      # Use \w* which can match zero-width (empty) strings
      patterns = %{word: ~r/\w*/}
      # String has spaces between words, where \w* matches empty string
      string = "hello world"

      result = Extractor.extract_from_string(string, patterns)

      # Should only have non-empty matches ("hello" and "world")
      # Empty matches (at spaces and boundaries) are filtered out
      assert result == %{word: ["hello", "world"]}
    end

    test "handles pattern with capture groups" do
      # When pattern has capture groups, the full match is used (not the captured group)
      patterns = %{id: ~r/id=(\d+)/}
      string = "id=123 and id=456"

      result = Extractor.extract_from_string(string, patterns)

      # Should extract the full match, not just the captured group
      assert result == %{id: ["id=123", "id=456"]}
    end

    test "handles overlapping matches - longest match wins" do
      patterns = %{
        number: ~r/\d+/,
        sku: ~r/\d{4}-\d{4}/
      }

      string = "SKU 1234-5678"

      result = Extractor.extract_from_string(string, patterns)

      # Most specific pattern (longest match) should win
      # sku pattern matches "1234-5678" (length 9)
      # number pattern would match "1234" and "5678" (length 4 each)
      # Since they overlap, only the longest (sku) is kept
      assert result == %{sku: ["1234-5678"]}
      refute Map.has_key?(result, :number)
    end

    test "handles overlapping matches with same length - deterministic winner by pattern name" do
      # Two patterns that match the same text with the same length
      # The winner should be deterministic (alphabetically first pattern name)
      patterns = %{
        order_id: ~r/ORD-\w{4}/,
        code: ~r/ORD-\w{4}/
      }

      string = "Reference: ORD-1234"

      # Run multiple times to verify determinism
      results = for _ <- 1..10, do: Extractor.extract_from_string(string, patterns)

      # All results should be identical
      assert Enum.uniq(results) |> length() == 1

      # The winner should be :code (alphabetically first)
      result = hd(results)
      assert result == %{code: ["ORD-1234"]}
      refute Map.has_key?(result, :order_id)
    end

    test "preserves extraction order" do
      patterns = %{letter: ~r/[A-Z]/}
      string = "C B A"

      result = Extractor.extract_from_string(string, patterns)

      # Order should be preserved as they appear in string
      assert result == %{letter: ["C", "B", "A"]}
    end

    test "handles case-sensitive patterns" do
      patterns = %{word: ~r/[A-Z][a-z]+/}
      string = "Alice and ALICE and alice"

      result = Extractor.extract_from_string(string, patterns)

      # Should only match "Alice", not "ALICE" or "alice"
      assert result == %{word: ["Alice"]}
    end

    test "handles case-insensitive patterns" do
      patterns = %{word: ~r/alice/i}
      string = "Alice and ALICE and alice"

      result = Extractor.extract_from_string(string, patterns)

      # Should match all variations
      assert result == %{word: ["Alice", "ALICE", "alice"]}
    end

    test "handles multiline strings" do
      patterns = %{sku: ~r/\d{4}-\d{4}/}

      string = """
      Line 1: SKU 1234-5678
      Line 2: SKU 5678-9012
      """

      result = Extractor.extract_from_string(string, patterns)

      assert result == %{sku: ["1234-5678", "5678-9012"]}
    end

    test "handles empty string" do
      patterns = %{sku: ~r/\d{4}-\d{4}/}
      string = ""

      result = Extractor.extract_from_string(string, patterns)

      assert result == %{}
    end

    test "handles empty patterns map" do
      patterns = %{}
      string = "SKU 1234-5678"

      result = Extractor.extract_from_string(string, patterns)

      assert result == %{}
    end

    test "handles special regex characters in matches" do
      patterns = %{version: ~r/\d+\.\d+\.\d+/}
      string = "Version 1.2.3"

      result = Extractor.extract_from_string(string, patterns)

      assert result == %{version: ["1.2.3"]}
    end
  end

  describe "extract_from_request/2" do
    test "extracts from URI path" do
      request = %{
        "method" => "GET",
        "uri" => "http://example.com/users/user-123/profile"
      }

      patterns = %{user_id: ~r/user-\d+/}

      result = Extractor.extract_from_request(request, patterns)

      assert result == %{user_id: ["user-123"]}
    end

    test "extracts from query string" do
      request = %{
        "method" => "GET",
        "uri" => "http://example.com/search",
        "query_string" => "sku=1234-5678&order=ORD-999"
      }

      patterns = %{
        sku: ~r/\d{4}-\d{4}/,
        order_id: ~r/ORD-\d+/
      }

      result = Extractor.extract_from_request(request, patterns)

      assert result == %{
               sku: ["1234-5678"],
               order_id: ["ORD-999"]
             }
    end

    test "extracts from JSON body" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com/create",
        "body_type" => "json",
        "body_json" => %{
          "sku" => "1234-5678",
          "description" => "Product with SKU 5678-9012"
        }
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_request(request, patterns)

      # Should find both SKUs (order may vary due to JSON serialization)
      assert Map.get(result, :sku) |> Enum.sort() == ["1234-5678", "5678-9012"]
    end

    test "extracts from text body" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com/submit",
        "body_type" => "text",
        "body" => "Order ORD-123 for SKU 1234-5678"
      }

      patterns = %{
        sku: ~r/\d{4}-\d{4}/,
        order_id: ~r/ORD-\d+/
      }

      result = Extractor.extract_from_request(request, patterns)

      assert result == %{
               sku: ["1234-5678"],
               order_id: ["ORD-123"]
             }
    end

    test "extracts from all sources in order: URI → query → body" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com/items/1234-5678",
        "query_string" => "related=5678-9012",
        "body_type" => "text",
        "body" => "Additional SKU: 9012-3456"
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_request(request, patterns)

      # Order should be: URI first, query second, body third
      assert result == %{sku: ["1234-5678", "5678-9012", "9012-3456"]}
    end

    test "handles request without query string" do
      request = %{
        "method" => "GET",
        "uri" => "http://example.com/items/1234-5678"
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_request(request, patterns)

      assert result == %{sku: ["1234-5678"]}
    end

    test "handles request without body" do
      request = %{
        "method" => "GET",
        "uri" => "http://example.com/items/1234-5678",
        "query_string" => "filter=active"
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_request(request, patterns)

      assert result == %{sku: ["1234-5678"]}
    end

    test "handles blob body (no extraction)" do
      # Use valid base64 encoded data
      binary_data = <<137, 80, 78, 71, 13, 10, 26, 10>>
      base64_data = Base.encode64(binary_data)

      request = %{
        "method" => "POST",
        "uri" => "http://example.com/upload",
        "body_type" => "blob",
        "body_blob" => base64_data
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_request(request, patterns)

      # Blob bodies are not extracted
      assert result == %{}
    end

    test "handles invalid base64 in body_blob gracefully" do
      # Invalid base64 data
      request = %{
        "method" => "POST",
        "uri" => "http://example.com/upload",
        "body_type" => "blob",
        "body_blob" => "!!!not-valid-base64!!!"
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      # Should not crash, should return empty result
      result = Extractor.extract_from_request(request, patterns)

      assert result == %{}
    end

    test "handles nested JSON structures" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com/create",
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "1234-5678"},
            %{"sku" => "5678-9012"}
          ],
          "metadata" => %{
            "source_sku" => "9012-3456"
          }
        }
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_request(request, patterns)

      # Should find all SKUs in nested structure
      assert result == %{sku: ["1234-5678", "5678-9012", "9012-3456"]}
    end

    test "handles empty patterns" do
      request = %{
        "method" => "GET",
        "uri" => "http://example.com/items/1234-5678"
      }

      patterns = %{}

      result = Extractor.extract_from_request(request, patterns)

      assert result == %{}
    end
  end

  describe "extract_from_response/2" do
    test "extracts from JSON body" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "sku" => "1234-5678",
          "related" => ["5678-9012", "9012-3456"]
        }
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_response(response, patterns)

      # Should find all SKUs (order may vary due to JSON serialization)
      assert Map.get(result, :sku) |> Enum.sort() == ["1234-5678", "5678-9012", "9012-3456"]
    end

    test "extracts from text body" do
      response = %{
        "status" => 200,
        "body_type" => "text",
        "body" => "Result: SKU 1234-5678 and SKU 5678-9012"
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_response(response, patterns)

      assert result == %{sku: ["1234-5678", "5678-9012"]}
    end

    test "handles blob body (no extraction)" do
      # Use valid base64 encoded data
      binary_data = <<137, 80, 78, 71, 13, 10, 26, 10>>
      base64_data = Base.encode64(binary_data)

      response = %{
        "status" => 200,
        "body_type" => "blob",
        "body_blob" => base64_data
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_response(response, patterns)

      # Blob bodies are not extracted
      assert result == %{}
    end

    test "handles response without body" do
      response = %{
        "status" => 204
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_response(response, patterns)

      assert result == %{}
    end

    test "handles nested JSON in response" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "results" => [
            %{"sku" => "1234-5678"},
            %{"sku" => "5678-9012"}
          ]
        }
      }

      patterns = %{sku: ~r/\d{4}-\d{4}/}

      result = Extractor.extract_from_response(response, patterns)

      assert result == %{sku: ["1234-5678", "5678-9012"]}
    end
  end

  describe "scan_response/2" do
    test "identifies which request variables appear in response" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "sku" => "1234-5678",
          "name" => "Widget"
        }
      }

      request_vars = %{
        sku: ["1234-5678"],
        order_id: ["ORD-999"]
      }

      result = Extractor.scan_response(response, request_vars)

      # scan_response returns a MapSet of variable.index strings
      # The set should contain sku.0 but not order_id
      assert MapSet.member?(result, "sku.0")
      refute MapSet.member?(result, "order_id.0")
    end

    test "finds variables in nested response structures" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "1234-5678"}
          ]
        }
      }

      request_vars = %{
        sku: ["1234-5678"],
        other: ["value"]
      }

      result = Extractor.scan_response(response, request_vars)

      assert MapSet.member?(result, "sku.0")
      refute MapSet.member?(result, "other.0")
    end

    test "finds variables in text body" do
      response = %{
        "status" => 200,
        "body_type" => "text",
        "body" => "Result for SKU 1234-5678"
      }

      request_vars = %{
        sku: ["1234-5678"],
        order_id: ["ORD-999"]
      }

      result = Extractor.scan_response(response, request_vars)

      assert MapSet.member?(result, "sku.0")
      refute MapSet.member?(result, "order_id.0")
    end

    test "returns empty set when no variables found in response" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"status" => "ok"}
      }

      request_vars = %{
        sku: ["1234-5678"]
      }

      result = Extractor.scan_response(response, request_vars)

      assert MapSet.size(result) == 0
    end

    test "returns empty set for blob response" do
      # Use valid base64 encoded data
      binary_data = <<137, 80, 78, 71, 13, 10, 26, 10>>
      base64_data = Base.encode64(binary_data)

      response = %{
        "status" => 200,
        "body_type" => "blob",
        "body_blob" => base64_data
      }

      request_vars = %{
        sku: ["1234-5678"]
      }

      result = Extractor.scan_response(response, request_vars)

      assert MapSet.size(result) == 0
    end

    test "handles multiple values for same variable" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "first" => "1234-5678",
          "second" => "5678-9012"
        }
      }

      request_vars = %{
        sku: ["1234-5678", "5678-9012"]
      }

      result = Extractor.scan_response(response, request_vars)

      # Should identify both sku.0 and sku.1
      assert MapSet.member?(result, "sku.0")
      assert MapSet.member?(result, "sku.1")
    end

    test "only returns variables where at least one value appears" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "sku" => "1234-5678"
        }
      }

      request_vars = %{
        sku: ["1234-5678", "9999-9999"],
        # Only first value appears
        other: ["not-in-response"]
      }

      result = Extractor.scan_response(response, request_vars)

      # sku.0 should be included because it appears
      assert MapSet.member?(result, "sku.0")
      # sku.1 should not be included because it doesn't appear
      refute MapSet.member?(result, "sku.1")
      # other should not be included
      refute MapSet.member?(result, "other.0")
    end

    test "handles empty request vars" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"sku" => "1234-5678"}
      }

      result = Extractor.scan_response(response, %{})

      assert MapSet.size(result) == 0
    end
  end
end
