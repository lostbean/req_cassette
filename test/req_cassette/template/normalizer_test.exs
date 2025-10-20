defmodule ReqCassette.Template.NormalizerTest do
  use ExUnit.Case, async: true

  alias ReqCassette.Template.Normalizer

  describe "normalize_json/1" do
    test "sorts map keys alphabetically" do
      input = %{"zebra" => 1, "apple" => 2, "banana" => 3}
      result = Normalizer.normalize_json(input)

      # Extract keys to verify order
      keys = Map.keys(result)
      assert keys == ["apple", "banana", "zebra"]
    end

    test "preserves array order" do
      input = [3, 1, 2]
      result = Normalizer.normalize_json(input)
      assert result == [3, 1, 2]
    end

    test "sorts nested map keys" do
      input = %{
        "z_outer" => %{
          "z_inner" => 1,
          "a_inner" => 2
        },
        "a_outer" => %{
          "z_inner" => 3,
          "a_inner" => 4
        }
      }

      result = Normalizer.normalize_json(input)

      # Check outer keys are sorted
      outer_keys = Map.keys(result)
      assert outer_keys == ["a_outer", "z_outer"]

      # Check inner keys are sorted
      inner_keys_a = Map.keys(result["a_outer"])
      assert inner_keys_a == ["a_inner", "z_inner"]

      inner_keys_z = Map.keys(result["z_outer"])
      assert inner_keys_z == ["a_inner", "z_inner"]
    end

    test "sorts maps inside arrays" do
      input = [
        %{"z" => 1, "a" => 2},
        %{"y" => 3, "b" => 4}
      ]

      result = Normalizer.normalize_json(input)

      # Array order preserved, but map keys sorted
      assert Map.keys(Enum.at(result, 0)) == ["a", "z"]
      assert Map.keys(Enum.at(result, 1)) == ["b", "y"]
    end

    test "handles deeply nested structures" do
      input = %{
        "level1_z" => %{
          "level2_z" => %{
            "level3_z" => 1,
            "level3_a" => 2
          },
          "level2_a" => 3
        },
        "level1_a" => 4
      }

      result = Normalizer.normalize_json(input)

      # All levels should be sorted
      assert Map.keys(result) == ["level1_a", "level1_z"]
      assert Map.keys(result["level1_z"]) == ["level2_a", "level2_z"]
      assert Map.keys(result["level1_z"]["level2_z"]) == ["level3_a", "level3_z"]
    end

    test "preserves non-map, non-array values" do
      assert Normalizer.normalize_json("string") == "string"
      assert Normalizer.normalize_json(42) == 42
      assert Normalizer.normalize_json(3.14) == 3.14
      assert Normalizer.normalize_json(true) == true
      assert Normalizer.normalize_json(false) == false
      assert Normalizer.normalize_json(nil) == nil
    end

    test "handles empty map" do
      assert Normalizer.normalize_json(%{}) == %{}
    end

    test "handles empty array" do
      assert Normalizer.normalize_json([]) == []
    end

    test "handles mixed types in array" do
      input = [
        %{"z" => 1, "a" => 2},
        "string",
        42,
        [1, 2, 3],
        true
      ]

      result = Normalizer.normalize_json(input)

      # Array order preserved
      assert length(result) == 5
      # First element (map) should have sorted keys
      assert Map.keys(Enum.at(result, 0)) == ["a", "z"]
      # Other elements unchanged
      assert Enum.at(result, 1) == "string"
      assert Enum.at(result, 2) == 42
      assert Enum.at(result, 3) == [1, 2, 3]
      assert Enum.at(result, 4) == true
    end

    test "handles duplicate key values (should be impossible in maps)" do
      # In Elixir, duplicate keys overwrite previous values
      # This just verifies the behavior
      input = %{"key" => 1}
      result = Normalizer.normalize_json(input)
      assert result == %{"key" => 1}
    end

    test "is idempotent" do
      input = %{"z" => 1, "a" => 2, "m" => 3}
      first_pass = Normalizer.normalize_json(input)
      second_pass = Normalizer.normalize_json(first_pass)
      assert first_pass == second_pass
    end
  end

  describe "normalize_query_string/1" do
    test "sorts query parameters alphabetically" do
      input = "zebra=1&apple=2&banana=3"
      result = Normalizer.normalize_query_string(input)
      assert result == "apple=2&banana=3&zebra=1"
    end

    test "handles empty query string" do
      assert Normalizer.normalize_query_string("") == ""
    end

    test "handles single parameter" do
      assert Normalizer.normalize_query_string("key=value") == "key=value"
    end

    test "handles parameters with special characters" do
      input = "key=hello%20world&another=test"
      result = Normalizer.normalize_query_string(input)
      assert result == "another=test&key=hello%20world"
    end

    test "handles parameters without values" do
      input = "flag&other=value"
      result = Normalizer.normalize_query_string(input)
      # Parameters without '=' should be preserved
      assert result =~ "flag"
      assert result =~ "other=value"
    end

    test "handles duplicate parameter names" do
      input = "key=value1&key=value2&other=value3"
      result = Normalizer.normalize_query_string(input)
      # Should preserve all values and sort
      assert result =~ "key=value1"
      assert result =~ "key=value2"
      assert result =~ "other=value3"
      # Verify sorting (key before other)
      assert String.starts_with?(result, "key=")
    end

    test "handles parameters in already-sorted order" do
      input = "apple=1&banana=2&zebra=3"
      result = Normalizer.normalize_query_string(input)
      assert result == input
    end

    test "is idempotent" do
      input = "z=1&a=2&m=3"
      first_pass = Normalizer.normalize_query_string(input)
      second_pass = Normalizer.normalize_query_string(first_pass)
      assert first_pass == second_pass
    end

    test "handles empty values" do
      input = "key=&other=value"
      result = Normalizer.normalize_query_string(input)
      assert result =~ "key="
      assert result =~ "other=value"
    end

    test "handles nil input" do
      assert Normalizer.normalize_query_string(nil) == ""
    end
  end

  describe "normalize_request/1" do
    test "normalizes JSON body" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com",
        "body_type" => "json",
        "body_json" => %{"z" => 1, "a" => 2}
      }

      result = Normalizer.normalize_request(request)

      # Body JSON should be sorted
      assert Map.keys(result["body_json"]) == ["a", "z"]
    end

    test "normalizes query string" do
      request = %{
        "method" => "GET",
        "uri" => "http://example.com",
        "query_string" => "z=1&a=2"
      }

      result = Normalizer.normalize_request(request)

      # Query string should be sorted
      assert result["query_string"] == "a=2&z=1"
    end

    test "normalizes both JSON body and query string" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com",
        "query_string" => "z=1&a=2",
        "body_type" => "json",
        "body_json" => %{"z" => 1, "a" => 2}
      }

      result = Normalizer.normalize_request(request)

      # Both should be sorted
      assert result["query_string"] == "a=2&z=1"
      assert Map.keys(result["body_json"]) == ["a", "z"]
    end

    test "preserves other fields" do
      request = %{
        "method" => "GET",
        "uri" => "http://example.com",
        "headers" => %{"authorization" => "Bearer token"},
        "query_string" => "z=1&a=2"
      }

      result = Normalizer.normalize_request(request)

      # Other fields preserved
      assert result["method"] == "GET"
      assert result["uri"] == "http://example.com"
      assert result["headers"] == %{"authorization" => "Bearer token"}
    end

    test "handles request without body" do
      request = %{
        "method" => "GET",
        "uri" => "http://example.com"
      }

      result = Normalizer.normalize_request(request)
      assert result == request
    end

    test "handles request without query string" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com",
        "body_type" => "json",
        "body_json" => %{"z" => 1, "a" => 2}
      }

      result = Normalizer.normalize_request(request)

      # Only body should be normalized
      assert Map.keys(result["body_json"]) == ["a", "z"]
    end

    test "handles text body (no normalization)" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com",
        "body_type" => "text",
        "body" => "plain text content"
      }

      result = Normalizer.normalize_request(request)

      # Text body should be unchanged
      assert result["body"] == "plain text content"
    end

    test "handles blob body (no normalization)" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com",
        "body_type" => "blob",
        "body_blob" => "base64encodeddata"
      }

      result = Normalizer.normalize_request(request)

      # Blob body should be unchanged
      assert result["body_blob"] == "base64encodeddata"
    end

    test "is idempotent" do
      request = %{
        "method" => "POST",
        "uri" => "http://example.com",
        "query_string" => "z=1&a=2",
        "body_type" => "json",
        "body_json" => %{"z" => 1, "a" => 2}
      }

      first_pass = Normalizer.normalize_request(request)
      second_pass = Normalizer.normalize_request(first_pass)
      assert first_pass == second_pass
    end
  end

  describe "normalize_response/1" do
    test "normalizes JSON body" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"z" => 1, "a" => 2}
      }

      result = Normalizer.normalize_response(response)

      # Body JSON should be sorted
      assert Map.keys(result["body_json"]) == ["a", "z"]
    end

    test "normalizes nested JSON" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "z_outer" => %{"z_inner" => 1, "a_inner" => 2},
          "a_outer" => 3
        }
      }

      result = Normalizer.normalize_response(response)

      # All levels should be sorted
      assert Map.keys(result["body_json"]) == ["a_outer", "z_outer"]
      assert Map.keys(result["body_json"]["z_outer"]) == ["a_inner", "z_inner"]
    end

    test "preserves other fields" do
      response = %{
        "status" => 200,
        "headers" => %{"content-type" => "application/json"},
        "body_type" => "json",
        "body_json" => %{"z" => 1, "a" => 2}
      }

      result = Normalizer.normalize_response(response)

      # Other fields preserved
      assert result["status"] == 200
      assert result["headers"] == %{"content-type" => "application/json"}
    end

    test "handles response without body" do
      response = %{
        "status" => 204
      }

      result = Normalizer.normalize_response(response)
      assert result == response
    end

    test "handles text body (no normalization)" do
      response = %{
        "status" => 200,
        "body_type" => "text",
        "body" => "plain text content"
      }

      result = Normalizer.normalize_response(response)

      # Text body should be unchanged
      assert result["body"] == "plain text content"
    end

    test "handles blob body (no normalization)" do
      response = %{
        "status" => 200,
        "body_type" => "blob",
        "body_blob" => "base64encodeddata"
      }

      result = Normalizer.normalize_response(response)

      # Blob body should be unchanged
      assert result["body_blob"] == "base64encodeddata"
    end

    test "is idempotent" do
      response = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"z" => 1, "a" => 2}
      }

      first_pass = Normalizer.normalize_response(response)
      second_pass = Normalizer.normalize_response(first_pass)
      assert first_pass == second_pass
    end
  end

  describe "normalization order determinism" do
    test "produces consistent results across multiple runs" do
      input = %{
        "method" => "POST",
        "uri" => "http://example.com",
        "query_string" => "param3=c&param1=a&param2=b",
        "body_type" => "json",
        "body_json" => %{
          "field3" => %{"nested2" => 2, "nested1" => 1},
          "field1" => "value1",
          "field2" => [%{"z" => 26, "a" => 1}]
        }
      }

      # Run normalization multiple times
      results =
        Enum.map(1..10, fn _ ->
          Normalizer.normalize_request(input)
        end)

      # All results should be identical
      first_result = hd(results)
      assert Enum.all?(results, fn result -> result == first_result end)
    end
  end
end
