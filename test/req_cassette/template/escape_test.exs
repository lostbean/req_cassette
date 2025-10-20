defmodule ReqCassette.Template.EscapeTest do
  use ExUnit.Case, async: true

  alias ReqCassette.Template.Escape

  describe "escape/1" do
    test "escapes backslashes" do
      assert Escape.escape("C:\\path\\file") == "C:\\\\path\\\\file"
    end

    test "escapes opening braces" do
      assert Escape.escape("Use {{var}} here") == "Use \\{\\{var\\}\\} here"
    end

    test "escapes closing braces" do
      assert Escape.escape("template}}end") == "template\\}\\}end"
    end

    test "escapes all special characters together" do
      assert Escape.escape("\\{{value}}\\") == "\\\\\\{\\{value\\}\\}\\\\"
    end

    test "handles empty string" do
      assert Escape.escape("") == ""
    end

    test "handles string with no special characters" do
      assert Escape.escape("hello world") == "hello world"
    end

    test "handles multiple occurrences" do
      input = "{{first}} and {{second}} and \\ backslash"
      expected = "\\{\\{first\\}\\} and \\{\\{second\\}\\} and \\\\ backslash"
      assert Escape.escape(input) == expected
    end

    test "escapes in correct order (backslash first)" do
      # This is critical - backslash must be escaped BEFORE braces
      # Otherwise we'd double-escape the escape sequence
      input = "\\{{"
      # Should become: \\\\\\{\\{
      # Not: \\\\{\\{
      result = Escape.escape(input)
      assert result == "\\\\\\{\\{"
    end
  end

  describe "unescape/1" do
    test "unescapes backslashes" do
      assert Escape.unescape("C:\\\\path\\\\file") == "C:\\path\\file"
    end

    test "unescapes opening braces" do
      assert Escape.unescape("Use \\{\\{var}} here") == "Use {{var}} here"
    end

    test "unescapes closing braces" do
      assert Escape.unescape("template\\}\\}end") == "template}}end"
    end

    test "unescapes all special characters together" do
      assert Escape.unescape("\\\\\\{\\{value\\}\\}\\\\") == "\\{{value}}\\"
    end

    test "handles empty string" do
      assert Escape.unescape("") == ""
    end

    test "handles string with no escape sequences" do
      assert Escape.unescape("hello world") == "hello world"
    end

    test "handles multiple occurrences" do
      input = "\\{\\{first}} and \\{\\{second}} and \\\\ backslash"
      expected = "{{first}} and {{second}} and \\ backslash"
      assert Escape.unescape(input) == expected
    end
  end

  describe "escape_json/1" do
    test "escapes strings in map" do
      input = %{"key" => "{{value}}"}
      expected = %{"key" => "\\{\\{value\\}\\}"}
      assert Escape.escape_json(input) == expected
    end

    test "escapes strings in nested maps" do
      input = %{"outer" => %{"inner" => "{{nested}}"}}
      expected = %{"outer" => %{"inner" => "\\{\\{nested\\}\\}"}}
      assert Escape.escape_json(input) == expected
    end

    test "escapes strings in arrays" do
      input = ["{{first}}", "{{second}}"]
      expected = ["\\{\\{first\\}\\}", "\\{\\{second\\}\\}"]
      assert Escape.escape_json(input) == expected
    end

    test "escapes strings in mixed structures" do
      input = %{
        "array" => ["{{item1}}", "{{item2}}"],
        "nested" => %{"value" => "{{nested}}"}
      }

      expected = %{
        "array" => ["\\{\\{item1\\}\\}", "\\{\\{item2\\}\\}"],
        "nested" => %{"value" => "\\{\\{nested\\}\\}"}
      }

      assert Escape.escape_json(input) == expected
    end

    test "preserves numbers" do
      input = %{"count" => 42, "price" => 99.99}
      assert Escape.escape_json(input) == input
    end

    test "preserves booleans" do
      input = %{"active" => true, "deleted" => false}
      assert Escape.escape_json(input) == input
    end

    test "preserves nil" do
      input = %{"value" => nil}
      assert Escape.escape_json(input) == input
    end

    test "handles deeply nested structures" do
      input = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "value" => "{{deep}}"
            }
          }
        }
      }

      expected = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "value" => "\\{\\{deep\\}\\}"
            }
          }
        }
      }

      assert Escape.escape_json(input) == expected
    end

    test "handles empty map" do
      assert Escape.escape_json(%{}) == %{}
    end

    test "handles empty array" do
      assert Escape.escape_json([]) == []
    end
  end

  describe "unescape_json/1" do
    test "unescapes strings in map" do
      input = %{"key" => "\\{\\{value\\}\\}"}
      expected = %{"key" => "{{value}}"}
      assert Escape.unescape_json(input) == expected
    end

    test "unescapes strings in nested maps" do
      input = %{"outer" => %{"inner" => "\\{\\{nested\\}\\}"}}
      expected = %{"outer" => %{"inner" => "{{nested}}"}}
      assert Escape.unescape_json(input) == expected
    end

    test "unescapes strings in arrays" do
      input = ["\\{\\{first\\}\\}", "\\{\\{second\\}\\}"]
      expected = ["{{first}}", "{{second}}"]
      assert Escape.unescape_json(input) == expected
    end

    test "unescapes strings in mixed structures" do
      input = %{
        "array" => ["\\{\\{item1\\}\\}", "\\{\\{item2\\}\\}"],
        "nested" => %{"value" => "\\{\\{nested\\}\\}"}
      }

      expected = %{
        "array" => ["{{item1}}", "{{item2}}"],
        "nested" => %{"value" => "{{nested}}"}
      }

      assert Escape.unescape_json(input) == expected
    end

    test "preserves numbers" do
      input = %{"count" => 42, "price" => 99.99}
      assert Escape.unescape_json(input) == input
    end

    test "preserves booleans" do
      input = %{"active" => true, "deleted" => false}
      assert Escape.unescape_json(input) == input
    end

    test "preserves nil" do
      input = %{"value" => nil}
      assert Escape.unescape_json(input) == input
    end

    test "handles deeply nested structures" do
      input = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "value" => "\\{\\{deep\\}\\}"
            }
          }
        }
      }

      expected = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "value" => "{{deep}}"
            }
          }
        }
      }

      assert Escape.unescape_json(input) == expected
    end

    test "handles empty map" do
      assert Escape.unescape_json(%{}) == %{}
    end

    test "handles empty array" do
      assert Escape.unescape_json([]) == []
    end
  end

  describe "round-trip encoding" do
    test "unescape(escape(x)) == x for simple string" do
      original = "{{value}} and \\ backslash"
      assert original |> Escape.escape() |> Escape.unescape() == original
    end

    test "unescape(escape(x)) == x for complex string" do
      original = "\\{{mixed\\}} with \\{\\{ already escaped"
      assert original |> Escape.escape() |> Escape.unescape() == original
    end

    test "unescape_json(escape_json(x)) == x for simple map" do
      original = %{"key" => "{{value}}"}
      assert original |> Escape.escape_json() |> Escape.unescape_json() == original
    end

    test "unescape_json(escape_json(x)) == x for complex structure" do
      original = %{
        "strings" => ["{{a}}", "{{b}}"],
        "nested" => %{
          "value" => "\\backslash and {{braces}}"
        },
        "numbers" => [1, 2, 3],
        "bool" => true,
        "null" => nil
      }

      assert original |> Escape.escape_json() |> Escape.unescape_json() == original
    end

    test "multiple round-trips preserve data" do
      original = %{"value" => "{{test}}"}

      result =
        original
        |> Escape.escape_json()
        |> Escape.unescape_json()
        |> Escape.escape_json()
        |> Escape.unescape_json()

      assert result == original
    end
  end

  describe "edge cases" do
    test "handles already-escaped content" do
      # If content is already escaped, escaping again should double-escape
      input = "\\{\\{value\\}\\}"
      escaped = Escape.escape(input)
      # Should become: \\\\\\{\\\\\\{value\\\\\\}\\\\\\}
      assert escaped != input

      # Unescaping once should return to the escaped form
      assert Escape.unescape(escaped) == input
    end

    test "handles mixed escaped and unescaped content" do
      input = "{{unescaped}} and \\{\\{escaped}}"
      escaped = Escape.escape(input)
      # {{unescaped}} becomes \\{\\{unescaped\\}\\}
      # \\{\\{escaped}} becomes \\\\{\\\\{escaped\\}\\}
      assert escaped =~ "\\{\\{unescaped\\}\\}"
      assert escaped =~ "\\\\{\\\\{escaped\\}\\}"
    end

    test "handles string with only backslashes" do
      assert Escape.escape("\\\\\\") == "\\\\\\\\\\\\"
      assert Escape.unescape("\\\\\\\\\\\\") == "\\\\\\"
    end

    test "handles string with only braces" do
      assert Escape.escape("{{}}") == "\\{\\{\\}\\}"
      assert Escape.unescape("\\{\\{\\}\\}") == "{{}}"
    end

    test "handles nil input gracefully" do
      # The escape function expects binary strings, not nil
      # This test verifies the type constraint
      assert_raise FunctionClauseError, fn ->
        Escape.escape(nil)
      end

      assert_raise FunctionClauseError, fn ->
        Escape.unescape(nil)
      end
    end

    test "escapes map keys when they are strings" do
      # Map keys should also be escaped
      input = %{"{{key}}" => "{{value}}"}
      # Note: In Elixir, maps preserve keys as-is, but we should still escape them
      # The current implementation might not escape keys - this tests the behavior
      result = Escape.escape_json(input)
      # Both key and value should have escaped braces
      assert Enum.any?(result, fn {k, v} ->
               String.contains?(k, "\\{\\{") and String.contains?(v, "\\{\\{")
             end)
    end
  end
end
