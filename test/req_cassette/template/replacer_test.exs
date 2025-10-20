defmodule ReqCassette.Template.ReplacerTest do
  use ExUnit.Case, async: true

  alias ReqCassette.Template.Replacer

  describe "replace_in_string/3" do
    test "replaces single value with template marker" do
      variables = %{sku: ["1234-5678"]}
      string = "Get SKU 1234-5678"
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      assert result == "Get SKU {{sku.0}}"
    end

    test "replaces multiple occurrences with value-based markers" do
      variables = %{sku: ["1234-5678", "5678-9012"]}
      string = "SKU 1234-5678 and SKU 5678-9012"
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      assert result == "SKU {{sku.0}} and SKU {{sku.1}}"
    end

    test "replaces duplicate values with same marker" do
      variables = %{sku: ["1234-5678", "1234-5678"]}
      string = "SKU 1234-5678 twice: 1234-5678"
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      # Duplicate values use the same marker (first occurrence)
      assert result == "SKU {{sku.0}} twice: {{sku.0}}"
    end

    test "replaces multiple different variables" do
      variables = %{
        sku: ["1234-5678"],
        order_id: ["ORD-999"]
      }

      string = "Order ORD-999 for SKU 1234-5678"
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      assert result == "Order {{order_id.0}} for SKU {{sku.0}}"
    end

    test "handles empty variables map" do
      variables = %{}
      string = "No replacements here"
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      assert result == "No replacements here"
    end

    test "handles empty string" do
      variables = %{sku: ["1234-5678"]}
      string = ""
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      assert result == ""
    end

    test "escapes regex special characters in values" do
      variables = %{version: ["1.2.3"]}
      string = "Version 1.2.3"
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      # Dots should not be treated as regex wildcards
      assert result == "Version {{version.0}}"
    end

    test "replaces values in order of appearance" do
      variables = %{num: ["111", "222", "333"]}
      string = "Numbers: 111, 222, 333"
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      assert result == "Numbers: {{num.0}}, {{num.1}}, {{num.2}}"
    end

    test "preserves non-matching content" do
      variables = %{sku: ["1234-5678"]}
      string = "SKU 1234-5678 and other text 9999-9999"
      opts = []

      result = Replacer.replace_in_string(string, variables, opts)

      # 9999-9999 should remain unchanged
      assert result == "SKU {{sku.0}} and other text 9999-9999"
    end
  end

  describe "substitute_in_string/2" do
    test "substitutes single template marker with value" do
      template = "Get SKU {{sku.0}}"
      variables = %{sku: ["9999-8888"]}

      result = Replacer.substitute_in_string(template, variables)

      assert result == "Get SKU 9999-8888"
    end

    test "substitutes multiple value-based markers" do
      template = "SKU {{sku.0}} and SKU {{sku.1}}"
      variables = %{sku: ["1111-2222", "3333-4444"]}

      result = Replacer.substitute_in_string(template, variables)

      assert result == "SKU 1111-2222 and SKU 3333-4444"
    end

    test "substitutes different variables" do
      template = "Order {{order_id.0}} for SKU {{sku.0}}"

      variables = %{
        sku: ["1234-5678"],
        order_id: ["ORD-999"]
      }

      result = Replacer.substitute_in_string(template, variables)

      assert result == "Order ORD-999 for SKU 1234-5678"
    end

    test "handles template with no markers" do
      template = "No markers here"
      variables = %{sku: ["1234-5678"]}

      result = Replacer.substitute_in_string(template, variables)

      assert result == "No markers here"
    end

    test "handles empty template" do
      template = ""
      variables = %{sku: ["1234-5678"]}

      result = Replacer.substitute_in_string(template, variables)

      assert result == ""
    end

    test "handles empty variables map" do
      template = "Get SKU {{sku.0}}"
      variables = %{}

      result = Replacer.substitute_in_string(template, variables)

      # Markers remain unchanged if no variables provided
      assert result == "Get SKU {{sku.0}}"
    end

    test "preserves markers for missing variables" do
      template = "SKU {{sku.0}} and Order {{order_id.0}}"
      variables = %{sku: ["1234-5678"]}

      # order_id not provided
      result = Replacer.substitute_in_string(template, variables)

      # order_id marker should remain
      assert result == "SKU 1234-5678 and Order {{order_id.0}}"
    end

    test "preserves markers for out-of-bounds indices" do
      template = "SKU {{sku.0}}, {{sku.1}}, {{sku.2}}"
      variables = %{sku: ["1234-5678"]}

      # Only one value, but template expects 3
      result = Replacer.substitute_in_string(template, variables)

      # Only sku.0 should be substituted
      assert result == "SKU 1234-5678, {{sku.1}}, {{sku.2}}"
    end
  end

  describe "create_json_template/3" do
    test "templates string values in map" do
      data = %{"sku" => "1234-5678", "name" => "Widget"}
      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      assert result == %{"sku" => "{{sku.0}}", "name" => "Widget"}
    end

    test "preserves numbers (no templating)" do
      data = %{"sku" => "1234-5678", "count" => 5, "price" => 99.99}
      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      assert result == %{"sku" => "{{sku.0}}", "count" => 5, "price" => 99.99}
    end

    test "preserves booleans (no templating)" do
      data = %{"sku" => "1234-5678", "active" => true, "deleted" => false}
      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      assert result == %{"sku" => "{{sku.0}}", "active" => true, "deleted" => false}
    end

    test "preserves nil (no templating)" do
      data = %{"sku" => "1234-5678", "notes" => nil}
      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      assert result == %{"sku" => "{{sku.0}}", "notes" => nil}
    end

    test "templates nested maps" do
      data = %{
        "outer" => %{
          "inner" => %{
            "sku" => "1234-5678"
          }
        }
      }

      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      assert get_in(result, ["outer", "inner", "sku"]) == "{{sku.0}}"
    end

    test "templates strings in arrays" do
      data = %{"skus" => ["1234-5678", "5678-9012"]}
      variables = %{sku: ["1234-5678", "5678-9012"]}
      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      assert result == %{"skus" => ["{{sku.0}}", "{{sku.1}}"]}
    end

    test "preserves array order" do
      data = ["3", "1", "2"]
      variables = %{}
      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      assert result == ["3", "1", "2"]
    end

    test "templates map values but not keys by default" do
      data = %{"sku-1234-5678" => "1234-5678"}
      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all, allow_key_templates: false]

      result = Replacer.create_json_template(data, variables, opts)

      # Key should NOT be templated, only value
      assert result == %{"sku-1234-5678" => "{{sku.0}}"}
    end

    test "templates map keys when allow_key_templates is true" do
      data = %{"1234-5678" => "value"}
      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all, allow_key_templates: true]

      result = Replacer.create_json_template(data, variables, opts)

      # Both key and value should be templated
      assert result == %{"{{sku.0}}" => "value"}
    end

    test "handles scope option with specific variables" do
      data = %{
        "sku" => "1234-5678",
        "order_id" => "ORD-999"
      }

      variables = %{
        sku: ["1234-5678"],
        order_id: ["ORD-999"]
      }

      # Only template sku, not order_id
      # Scope should be a MapSet of "var.index" strings
      opts = [scope: MapSet.new(["sku.0"])]

      result = Replacer.create_json_template(data, variables, opts)

      assert result == %{"sku" => "{{sku.0}}", "order_id" => "ORD-999"}
    end

    test "handles scope: :all" do
      data = %{
        "sku" => "1234-5678",
        "order_id" => "ORD-999"
      }

      variables = %{
        sku: ["1234-5678"],
        order_id: ["ORD-999"]
      }

      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      # Both should be templated
      assert result == %{"sku" => "{{sku.0}}", "order_id" => "{{order_id.0}}"}
    end

    test "handles empty scope list" do
      data = %{"sku" => "1234-5678"}
      variables = %{sku: ["1234-5678"]}
      opts = [scope: []]

      result = Replacer.create_json_template(data, variables, opts)

      # Nothing should be templated
      assert result == %{"sku" => "1234-5678"}
    end

    test "handles complex nested structure" do
      data = %{
        "items" => [
          %{"sku" => "1234-5678", "count" => 1},
          %{"sku" => "5678-9012", "count" => 2}
        ],
        "metadata" => %{
          "source" => "9012-3456"
        }
      }

      variables = %{sku: ["1234-5678", "5678-9012", "9012-3456"]}
      opts = [scope: :all]

      result = Replacer.create_json_template(data, variables, opts)

      assert result == %{
               "items" => [
                 %{"sku" => "{{sku.0}}", "count" => 1},
                 %{"sku" => "{{sku.1}}", "count" => 2}
               ],
               "metadata" => %{
                 "source" => "{{sku.2}}"
               }
             }
    end
  end

  describe "apply_template_to_data/2" do
    test "substitutes variables in response with JSON body" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"sku" => "{{sku.0}}", "name" => "Widget"}
      }

      variables = %{sku: ["9999-8888"]}

      result = Replacer.apply_template_to_data(template, variables)

      assert result["body_json"] == %{"sku" => "9999-8888", "name" => "Widget"}
    end

    test "substitutes variables in nested JSON body" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "outer" => %{
            "inner" => %{
              "sku" => "{{sku.0}}"
            }
          }
        }
      }

      variables = %{sku: ["9999-8888"]}

      result = Replacer.apply_template_to_data(template, variables)

      assert get_in(result, ["body_json", "outer", "inner", "sku"]) == "9999-8888"
    end

    test "substitutes variables in JSON arrays" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"skus" => ["{{sku.0}}", "{{sku.1}}"]}
      }

      variables = %{sku: ["1111-2222", "3333-4444"]}

      result = Replacer.apply_template_to_data(template, variables)

      assert result["body_json"] == %{"skus" => ["1111-2222", "3333-4444"]}
    end

    test "preserves non-template values" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "sku" => "{{sku.0}}",
          "count" => 5,
          "active" => true,
          "notes" => nil
        }
      }

      variables = %{sku: ["9999-8888"]}

      result = Replacer.apply_template_to_data(template, variables)

      assert result["body_json"] == %{
               "sku" => "9999-8888",
               "count" => 5,
               "active" => true,
               "notes" => nil
             }
    end

    test "handles template with no markers" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"name" => "Widget", "count" => 5}
      }

      variables = %{sku: ["9999-8888"]}

      result = Replacer.apply_template_to_data(template, variables)

      assert result["body_json"] == %{"name" => "Widget", "count" => 5}
    end

    test "handles empty variables map" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"sku" => "{{sku.0}}"}
      }

      variables = %{}

      result = Replacer.apply_template_to_data(template, variables)

      # Markers should remain unchanged
      assert result["body_json"] == %{"sku" => "{{sku.0}}"}
    end

    test "substitutes in map keys when present" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"{{sku.0}}" => "value"}
      }

      variables = %{sku: ["9999-8888"]}

      result = Replacer.apply_template_to_data(template, variables)

      # Key should be substituted
      assert result["body_json"] == %{"9999-8888" => "value"}
    end

    test "handles complex structure with multiple variables" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "{{sku.0}}", "count" => 1},
            %{"sku" => "{{sku.1}}", "count" => 2}
          ],
          "order" => "{{order_id.0}}"
        }
      }

      variables = %{
        sku: ["1111-2222", "3333-4444"],
        order_id: ["ORD-555"]
      }

      result = Replacer.apply_template_to_data(template, variables)

      assert result["body_json"] == %{
               "items" => [
                 %{"sku" => "1111-2222", "count" => 1},
                 %{"sku" => "3333-4444", "count" => 2}
               ],
               "order" => "ORD-555"
             }
    end

    test "applies to text body" do
      template = %{
        "status" => 200,
        "body_type" => "text",
        "body" => "SKU {{sku.0}} and {{sku.1}}"
      }

      variables = %{sku: ["1111-2222", "3333-4444"]}

      result = Replacer.apply_template_to_data(template, variables)

      assert result["body"] == "SKU 1111-2222 and 3333-4444"
    end

    test "applies to JSON body with array at root" do
      template = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => ["{{sku.0}}", "{{sku.1}}", "static"]
      }

      variables = %{sku: ["1111-2222", "3333-4444"]}

      result = Replacer.apply_template_to_data(template, variables)

      assert result["body_json"] == ["1111-2222", "3333-4444", "static"]
    end
  end

  describe "create_template_from_data/3" do
    test "creates template from request with text body" do
      data = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "text",
        "body" => "Get SKU 1234-5678"
      }

      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      assert result["body"] == "Get SKU {{sku.0}}"
    end

    test "creates template from request with JSON body" do
      data = %{
        "method" => "POST",
        "uri" => "http://example.com/api",
        "body_type" => "json",
        "body_json" => %{"sku" => "1234-5678", "name" => "Widget"}
      }

      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      assert result["body_json"] == %{"sku" => "{{sku.0}}", "name" => "Widget"}
    end

    test "creates template from response with JSON body containing arrays" do
      data = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => ["1234-5678", "5678-9012"]
      }

      variables = %{sku: ["1234-5678", "5678-9012"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      assert result["body_json"] == ["{{sku.0}}", "{{sku.1}}"]
    end

    test "preserves non-string types in JSON body" do
      data = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{"sku" => "1234-5678", "count" => 5, "active" => true}
      }

      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # Only string should be templated
      assert result["body_json"] == %{"sku" => "{{sku.0}}", "count" => 5, "active" => true}
    end

    test "creates template from URI path" do
      data = %{
        "method" => "GET",
        "uri" => "http://example.com/products/1234-5678",
        "query_string" => "",
        "body" => ""
      }

      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # URI should be templated
      assert result["uri"] == "http://example.com/products/{{sku.0}}"
      assert result["body"] == ""
    end

    test "creates template from URI with multiple path segments" do
      data = %{
        "method" => "GET",
        "uri" => "http://example.com/users/user-123/orders/order-456",
        "query_string" => "",
        "body" => ""
      }

      variables = %{
        user_id: ["user-123"],
        order_id: ["order-456"]
      }

      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # Both IDs in URI should be templated
      assert result["uri"] == "http://example.com/users/{{user_id.0}}/orders/{{order_id.0}}"
    end

    test "creates template from query string" do
      data = %{
        "method" => "GET",
        "uri" => "http://example.com/search",
        "query_string" => "sku=1234-5678&status=active",
        "body" => ""
      }

      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # Query string should be templated
      assert result["query_string"] == "sku={{sku.0}}&status=active"
    end

    test "creates template from multiple query parameters" do
      data = %{
        "method" => "GET",
        "uri" => "http://example.com/search",
        "query_string" => "primary=1111-2222&secondary=3333-4444&limit=10",
        "body" => ""
      }

      variables = %{sku: ["1111-2222", "3333-4444"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # Multiple SKUs in query should be templated
      assert result["query_string"] == "primary={{sku.0}}&secondary={{sku.1}}&limit=10"
    end

    test "creates template from both URI and query string" do
      data = %{
        "method" => "GET",
        "uri" => "http://example.com/products/1234-5678",
        "query_string" => "compare_with=9999-8888",
        "body" => ""
      }

      variables = %{sku: ["1234-5678", "9999-8888"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # Both URI and query string should be templated
      assert result["uri"] == "http://example.com/products/{{sku.0}}"
      assert result["query_string"] == "compare_with={{sku.1}}"
    end

    test "creates template from URI, query, and body together" do
      data = %{
        "method" => "POST",
        "uri" => "http://example.com/products/1234-5678",
        "query_string" => "action=update",
        "body" => "Update SKU 1234-5678 details"
      }

      variables = %{sku: ["1234-5678"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # All three should be templated with the same marker (duplicate value)
      assert result["uri"] == "http://example.com/products/{{sku.0}}"
      assert result["query_string"] == "action=update"
      assert result["body"] == "Update SKU {{sku.0}} details"
    end

    test "handles URI with port number that matches pattern" do
      data = %{
        "method" => "GET",
        "uri" => "http://localhost:8080/api/item/1234",
        "query_string" => "",
        "body" => ""
      }

      variables = %{id: ["8080", "1234"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # Both port and path ID should be templated
      assert result["uri"] == "http://localhost:{{id.0}}/api/item/{{id.1}}"
    end
  end

  describe "round-trip templating" do
    test "apply_template_to_data(create_template(...), new_vars) works correctly" do
      original_data = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "sku" => "1234-5678",
          "order" => "ORD-999",
          "name" => "Widget"
        }
      }

      original_vars = %{
        sku: ["1234-5678"],
        order_id: ["ORD-999"]
      }

      # Create template
      template = Replacer.create_template_from_data(original_data, original_vars, scope: :all)

      # Apply with new variables
      new_vars = %{
        sku: ["9999-8888"],
        order_id: ["ORD-111"]
      }

      result = Replacer.apply_template_to_data(template, new_vars)

      # Should have new values
      assert result["body_json"] == %{
               "sku" => "9999-8888",
               "order" => "ORD-111",
               "name" => "Widget"
             }
    end

    test "handles complex nested structure round-trip" do
      original_data = %{
        "status" => 200,
        "body_type" => "json",
        "body_json" => %{
          "items" => [
            %{"sku" => "1234-5678"},
            %{"sku" => "5678-9012"}
          ],
          "metadata" => %{
            "count" => 2,
            "source" => "API"
          }
        }
      }

      original_vars = %{sku: ["1234-5678", "5678-9012"]}

      # Create template
      template = Replacer.create_template_from_data(original_data, original_vars, scope: :all)

      # Apply with new variables
      new_vars = %{sku: ["AAAA-BBBB", "CCCC-DDDD"]}
      result = Replacer.apply_template_to_data(template, new_vars)

      # SKUs should be replaced
      assert result["body_json"]["items"] == [
               %{"sku" => "AAAA-BBBB"},
               %{"sku" => "CCCC-DDDD"}
             ]

      # Non-templated values preserved
      assert result["body_json"]["metadata"] == %{"count" => 2, "source" => "API"}
    end
  end

  describe "create_template/3 with invalid UTF-8" do
    test "returns content unchanged for invalid UTF-8 binary" do
      # Binary data that is not valid UTF-8
      binary_content = <<137, 80, 78, 71, 13, 10, 26, 10>>
      variables = %{id: ["12345"]}
      opts = []

      # Should not crash, just return content unchanged
      result = Replacer.create_template(binary_content, variables, opts)

      assert result == binary_content
    end

    test "returns content unchanged for binary with embedded null bytes" do
      # Binary with null bytes (common in binary files)
      binary_content = <<0, 1, 2, 3, 0, 0, 0, 0>>
      variables = %{id: ["12345"]}
      opts = []

      result = Replacer.create_template(binary_content, variables, opts)

      assert result == binary_content
    end

    test "still templates valid UTF-8 content normally" do
      # Valid UTF-8 with special characters
      content = "Get SKU 1234-5678 with café"
      variables = %{sku: ["1234-5678"]}
      opts = []

      result = Replacer.create_template(content, variables, opts)

      assert result == "Get SKU {{sku.0}} with café"
    end
  end

  describe "create_template_from_data/3 with blob bodies" do
    test "skips templating for body_blob data" do
      # Binary blob as base64
      blob_base64 = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)

      data = %{
        "status" => 200,
        "body_type" => "blob",
        "body_blob" => blob_base64
      }

      variables = %{id: ["12345"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # body_blob should be unchanged (not templated)
      assert result["body_blob"] == blob_base64
      assert result["body_type"] == "blob"
    end

    test "still templates uri even when body is blob" do
      blob_base64 = Base.encode64(<<137, 80, 78, 71>>)

      data = %{
        "method" => "GET",
        "uri" => "http://example.com/images/img-12345.png",
        "body_type" => "blob",
        "body_blob" => blob_base64
      }

      variables = %{image_id: ["img-12345"]}
      opts = [scope: :all]

      result = Replacer.create_template_from_data(data, variables, opts)

      # URI should be templated
      assert result["uri"] == "http://example.com/images/{{image_id.0}}.png"
      # Blob should be unchanged
      assert result["body_blob"] == blob_base64
    end
  end
end
