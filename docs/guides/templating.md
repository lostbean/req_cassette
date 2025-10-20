# Templating Guide

> **Parameterized cassettes for testing with dynamic values**

Templating allows a single cassette to handle multiple requests with different
dynamic values (IDs, SKUs, timestamps, etc.) while maintaining the same response
structure. This dramatically reduces cassette proliferation when testing APIs
with parameterized data.

## Table of Contents

- [What Are Templates?](#what-are-templates)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Pattern Syntax](#pattern-syntax)
- [Common Use Cases](#common-use-cases)
- [Template Variables](#template-variables)
- [Configuration Options](#configuration-options)
- [Debugging Failed Matches](#debugging-failed-matches)
- [JSON vs Text Templating](#json-vs-text-templating)
- [LLM API Integration](#llm-api-integration)
- [Best Practices](#best-practices)
- [Limitations](#limitations)

---

## What Are Templates?

Without templates, each unique request requires its own cassette:

```elixir
# ❌ Without templates - need 3 cassettes!
test "fetch SKU 1234-5678" do
  with_cassette "sku_1234_5678", fn plug ->
    response = API.get_sku("1234-5678", plug: plug)
    assert response.body["sku"] == "1234-5678"
  end
end

test "fetch SKU 5678-9012" do
  with_cassette "sku_5678_9012", fn plug ->
    response = API.get_sku("5678-9012", plug: plug)
    assert response.body["sku"] == "5678-9012"
  end
end
```

With templates, one cassette handles all variations:

```elixir
# ✅ With templates - single cassette for all SKUs!
test "fetch any SKU" do
  with_cassette "sku_lookup",
    [template: [patterns: [sku: ~r/\d{4}-\d{4}/]]],
    fn plug ->
      # First call records
      response1 = API.get_sku("1234-5678", plug: plug)
      assert response1.body["sku"] == "1234-5678"

      # Subsequent calls replay with different SKU!
      response2 = API.get_sku("9999-8888", plug: plug)
      assert response2.body["sku"] == "9999-8888"
    end
end
```

**How?** The template extracts `1234-5678` during recording, creates a template
with `{{sku.0}}`, and substitutes `9999-8888` during replay.

---

## Quick Start

### Basic Example

```elixir
import ReqCassette

test "product lookup with templates" do
  with_cassette "product_lookup",
    [
      template: [
        patterns: [sku: ~r/\d{4}-\d{4}/]
      ]
    ],
    fn plug ->
      # First run: Records real API call
      response = Req.get!(
        "https://api.example.com/products/1234-5678",
        plug: plug
      )

      assert response.body["sku"] == "1234-5678"
      assert response.body["name"] == "Widget"

      # Second run: Replays from cassette with different SKU!
      response2 = Req.get!(
        "https://api.example.com/products/5555-6666",
        plug: plug
      )

      assert response2.body["sku"] == "5555-6666"  # ✅ Substituted!
      assert response2.body["name"] == "Widget"     # ✅ Same static data
    end
end
```

### What Gets Saved?

The cassette stores a **template** instead of exact values:

```json
{
  "version": "2.0",
  "interactions": [
    {
      "template": {
        "enabled": true,
        "patterns": { "sku": "\\d{4}-\\d{4}" },
        "recorded_values": { "sku": ["1234-5678"] }
      },
      "request": {
        "uri": "https://api.example.com/products/{{sku.0}}",
        "method": "GET"
      },
      "response": {
        "body_json": {
          "sku": "{{sku.0}}",
          "name": "Widget"
        }
      }
    }
  ]
}
```

---

## How It Works

### Recording Flow

1. **Request arrives** with value `1234-5678`
2. **Filters applied** (if configured)
3. **Data normalized** (JSON keys sorted alphabetically)
4. **Pattern extraction** finds `1234-5678` matching `~r/\d{4}-\d{4}/`
5. **Template creation** replaces `1234-5678` with `{{sku.0}}`
6. **Response scanning** checks which variables appear in response
7. **Response templating** creates `{"sku": "{{sku.0}}"}`
8. **Cassette saved** with templated request and response

### Replay Flow

1. **Request arrives** with value `9999-8888`
2. **Filters applied** (same as recording)
3. **Data normalized** (same as recording)
4. **Pattern extraction** finds `9999-8888` matching pattern
5. **Template creation** creates incoming template: `{{sku.0}}`
6. **Template matching** compares structures (not values!)
   - Cassette: `{"sku": "{{sku.0}}"}`
   - Incoming: `{"sku": "{{sku.0}}"}`
   - **Match!** ✅
7. **Substitution** replaces `{{sku.0}}` with `9999-8888`
8. **Response returned** with new value substituted

---

## Pattern Syntax

Patterns use Elixir regular expressions to identify dynamic values.

### Basic Patterns

```elixir
template: [
  patterns: [
    # SKUs: 4 digits, dash, 4 digits
    sku: ~r/\d{4}-\d{4}/,

    # Order IDs: ORD- followed by numbers
    order_id: ~r/ORD-\d+/,

    # UUIDs
    uuid: ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,

    # Email addresses
    email: ~r/[\w.+-]+@[\w.-]+\.\w+/,

    # Timestamps (ISO 8601)
    timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/,

    # Semantic versions
    version: ~r/\d+\.\d+\.\d+/
  ]
]
```

### Pattern Naming

Use descriptive atom names that reflect the data:

```elixir
# ✅ Good names
patterns: [
  user_id: ~r/user-\d+/,
  product_sku: ~r/SKU-[A-Z0-9]+/,
  api_key: ~r/sk_live_\w+/
]

# ❌ Bad names (too generic)
patterns: [
  id: ~r/\d+/,           # Which ID?
  value: ~r/\w+/,        # What value?
  thing: ~r/[A-Z]+/      # What thing?
]
```

### Multiple Patterns

Templates support multiple patterns in a single cassette:

```elixir
with_cassette "order_workflow",
  [
    template: [
      patterns: [
        user_id: ~r/user-\d+/,
        order_id: ~r/ORD-\d+/,
        product_sku: ~r/\d{4}-\d{4}/,
        timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
      ]
    ]
  ],
  fn plug ->
    response = Req.post!(
      "https://api.example.com/orders",
      json: %{
        user_id: "user-12345",
        items: [
          %{sku: "1234-5678", quantity: 2},
          %{sku: "5678-9012", quantity: 1}
        ],
        timestamp: "2025-01-15T10:30:00Z"
      },
      plug: plug
    )
  end
```

### Pattern Overlap

If multiple patterns match **the same text** (overlapping positions), the **most
specific** (longest) match wins:

```elixir
patterns: [
  number: ~r/\d+/,           # Matches: "1234", "5678"
  sku: ~r/\d{4}-\d{4}/       # Matches: "1234-5678" (wins!)
]

# Input: "SKU 1234-5678"
# Result: %{sku: ["1234-5678"]}  (not %{number: ["1234", "5678"]})
```

**Important:** Non-overlapping matches from different patterns are both kept:

```elixir
patterns: [
  number: ~r/\d+/,
  sku: ~r/\d{4}-\d{4}/
]

# Input: "Port 8080 handling SKU 1234-5678"
# Result: %{number: ["8080"], sku: ["1234-5678"]}
# Both kept because "8080" and "1234-5678" don't overlap
```

### Empty Matches

Patterns that can match empty strings (using `*` quantifier) will have empty
matches filtered out:

```elixir
patterns: [word: ~r/\w*/]  # * can match zero characters

# Input: "hello world"
# Would match: ["hello", "", "world", "", ...]
# Result: %{word: ["hello", "world"]}  (empty matches removed)
```

**Tip:** Use `+` instead of `*` to avoid matching empty strings:

```elixir
# ✅ Better - only matches non-empty words
patterns: [word: ~r/\w+/]
```

---

## Common Use Cases

### 1. E-Commerce Product Lookups

```elixir
test "product lookup by SKU" do
  with_cassette "product_lookup",
    [template: [patterns: [sku: ~r/\d{4}-\d{4}/]]],
    fn plug ->
      # Test with multiple SKUs using same cassette
      for sku <- ["1234-5678", "5678-9012", "9012-3456"] do
        response = API.get_product(sku, plug: plug)
        assert response.body["sku"] == sku
        assert response.body["in_stock"] in [true, false]
      end
    end
end
```

### 2. User Management APIs

```elixir
test "user CRUD operations" do
  with_cassette "user_operations",
    [
      template: [
        patterns: [
          user_id: ~r/user-\d+/,
          email: ~r/[\w.+-]+@[\w.-]+\.\w+/
        ]
      ]
    ],
    fn plug ->
      # Create
      user = API.create_user("alice@example.com", plug: plug)

      # Read
      fetched = API.get_user(user.id, plug: plug)
      assert fetched.email == "alice@example.com"

      # Update with different email
      updated = API.update_user(user.id, "alice.new@example.com", plug: plug)
      assert updated.email == "alice.new@example.com"
    end
end
```

### 3. Time-Sensitive APIs

```elixir
test "analytics with timestamps" do
  with_cassette "analytics",
    [
      template: [
        patterns: [
          timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
        ]
      ]
    ],
    fn plug ->
      # Works with any timestamp!
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      response = API.get_analytics(
        start_time: now,
        plug: plug
      )

      assert response.status == 200
    end
end
```

### 4. Pagination

```elixir
test "paginated results" do
  with_cassette "users_paginated",
    [
      template: [
        patterns: [
          cursor: ~r/cursor_[a-zA-Z0-9]+/
        ]
      ]
    ],
    fn plug ->
      # First page
      page1 = API.list_users(plug: plug)
      assert length(page1.users) == 10

      # Second page with cursor
      page2 = API.list_users(
        cursor: page1.next_cursor,
        plug: plug
      )

      assert length(page2.users) == 10
    end
end
```

---

## Template Variables

### Variable Scope Rules

ReqCassette determines what to template based on where values appear:

| Value Location              | Behavior                               | Example                |
| --------------------------- | -------------------------------------- | ---------------------- |
| **Request only**            | Templated in request (wildcard match)  | Search filters         |
| **Response only**           | Not templated (static)                 | System-generated IDs   |
| **Both request & response** | **Templated in both!**                 | Echo APIs, SKU lookups |

#### Request-Only Values

Values that appear only in the request are **templated in the request** but remain constant in the response:

```elixir
# Request: "Search for SKU 1234-5678"
# Response: {"results": [...], "count": 5}
#
# SKU templated in request: "Search for SKU {{sku.0}}"
# Response stays constant (SKU doesn't appear in it)
# Acts as wildcard - different search SKUs match same cassette!
```

#### Response-Only Values

Values that appear only in the response are **static API data**:

```elixir
# Request: "Get system info"
# Response: {"system_sku": "1234-5678", "version": "1.0"}
#
# SKU only in response → literal value kept
# This is the API's fixed data, not user input
```

#### Shared Values (Templated in Both!)

Values appearing in **both** request and response are templated in **both places**:

```elixir
# Request: "Get SKU 1234-5678"
# Response: {"sku": "1234-5678", "name": "Widget"}
#
# SKU templated in both:
#   Request: "Get SKU {{sku.0}}"
#   Response: {"sku": "{{sku.0}}", "name": "Widget"}
# Replay with SKU 9999-8888 returns {"sku": "9999-8888", "name": "Widget"}
```

### Instance-Based Indexing

Template markers use **value-based indexing** where each unique value gets its
own instance identifier. The index number (`.0`, `.1`, etc.) identifies the
unique VALUE, not its position.

**Key insight:** Same value = same marker, regardless of position!

```elixir
# Example 1: Duplicate values
# Request: "SKU 1234-5678 and SKU 1234-5678 again"
# Unique values: ["1234-5678"]  # Only ONE unique value
# Template: "SKU {{sku.0}} and {{sku.0}} again"
#           ^^^^^^^^^^^^^    ^^^^^^^^^^^^^
#           Both get the same marker because they're the same value!
```

```elixir
# Example 2: Multiple different values
# Request: "Compare SKU 1111-2222 with SKU 3333-4444"
# Unique values: ["1111-2222", "3333-4444"]  # Two unique values
# Instance assignments:
#   sku.0 = "1111-2222"
#   sku.1 = "3333-4444"
# Template: "Compare {{sku.0}} with {{sku.1}}"
```

**During replay:**

```elixir
# Request: "Compare SKU 5555-6666 with SKU 7777-8888"
# Unique values: ["5555-6666", "7777-8888"]
# Instance assignments:
#   sku.0 = "5555-6666"
#   sku.1 = "7777-8888"
# Template: "Compare {{sku.0}} with {{sku.1}}"
# Matches recorded template! ✅
# Response substitution:
#   {{sku.0}} → "5555-6666"
#   {{sku.1}} → "7777-8888"
```

**What this means:**

- The `.N` suffix is an instance ID for each unique value, not a position
  counter
- If the same value appears 3 times, all 3 occurrences get the same marker
- Only unique values get different indices

---

## Configuration Options

### Basic Configuration

```elixir
template: [
  patterns: [
    sku: ~r/\d{4}-\d{4}/,
    order_id: ~r/ORD-\d+/
  ]
]
```

### Allow Key Templates

By default, only **JSON values** are templated, not keys. Enable key templating:

```elixir
template: [
  patterns: [sku: ~r/\d{4}-\d{4}/],
  allow_key_templates: true  # ⚠️ Advanced - use with caution
]
```

**Example:**

```elixir
# With allow_key_templates: false (default)
%{"1234-5678" => "data"}  # Key stays literal

# With allow_key_templates: true
%{"{{sku.0}}" => "data"}  # Key is templated
```

**When to use:**

- APIs that echo input as keys
- GraphQL field aliasing
- Dynamic key structures

**When NOT to use:**

- Standard REST APIs (rarely needed)
- If unsure (stick with default)

---

## Debugging Failed Matches

When templates don't match, you'll get detailed error messages:

### Example Error

```
No matching interaction found.

Template matching failed:
  Expected structure: "Get SKU {{sku.0}}"
  Actual structure:   "Get product {{sku.0}}"
  Difference: "Get SKU" vs "Get product"

Exact matching also failed:
  Expected: "Get SKU 1234-5678"
  Actual:   "Get product 5555-6666"

Hint: Request structure changed. Update cassette or adjust patterns.
```

### Common Issues

#### 1. Structure Changed

**Problem:** API endpoint or request format changed

```elixir
# Recorded: POST /api/v1/products
# Replaying: POST /api/v2/products  ❌ Mismatch!
```

**Solution:** Delete and re-record cassette

#### 2. Pattern Doesn't Match

**Problem:** Value doesn't match pattern

```elixir
patterns: [sku: ~r/\d{4}-\d{4}/]  # Expects: 1234-5678
# Request has: SKU-ABC-123  ❌ No match!
```

**Solution:** Adjust pattern or use exact match

#### 3. Extra/Missing Fields

**Problem:** JSON structure differs

```elixir
# Recorded: {"sku": "{{sku.0}}", "name": "Widget"}
# Replaying: {"sku": "{{sku.0}}"}  ❌ Missing "name"!
```

**Solution:** Ensure request structure matches

---

## JSON vs Text Templating

### JSON Templating

**Type-safe:** Only `string` values are templated. Numbers, booleans, and null
remain literal.

```elixir
# Input
%{
  "sku" => "1234-5678",    # String → templated
  "count" => 5,            # Number → literal
  "active" => true,        # Boolean → literal
  "notes" => nil           # Null → literal
}

# Template
%{
  "sku" => "{{sku.0}}",    # ✅ Templated
  "count" => 5,            # ✅ Literal (unchanged)
  "active" => true,        # ✅ Literal (unchanged)
  "notes" => nil           # ✅ Literal (unchanged)
}
```

**Limitation:** If non-string values vary between calls, you need separate
cassettes.

```elixir
# Recording: {"sku": "1234-5678", "count": 5}
# Replay: {"sku": "9999-8888", "count": 10}  ❌ Won't match!
# (count is literal 5, not templated)
```

### Text Templating

Text bodies (HTML, XML, plain text) template anywhere in the string:

```elixir
# Input (text body)
"Order ORD-123 for SKU 1234-5678"

# Template
"Order {{order_id.0}} for SKU {{sku.0}}"
```

### Binary/Blob Bodies

**Not supported:** Binary data (images, PDFs, etc.) cannot be templated.

```elixir
# Blob bodies are skipped
%{
  "body_type" => "blob",
  "body_blob" => "..."  # Not templated
}
```

---

## LLM API Integration

Templates are **perfect** for LLM APIs with dynamic conversation IDs,
timestamps, and variable prompts.

### Basic LLM Example

```elixir
test "chat completion with templates" do
  with_cassette "llm_chat",
    [
      template: [
        patterns: [
          conversation_id: ~r/conv_[a-zA-Z0-9]+/,
          message_id: ~r/msg_[a-zA-Z0-9]+/,
          timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
        ]
      ]
    ],
    fn plug ->
      # First test with original IDs
      {:ok, response1} = ReqLLM.generate_text(
        "anthropic:claude-sonnet-4-20250514",
        "Explain recursion",
        conversation_id: "conv_abc123",
        req_http_options: [plug: plug]
      )

      assert response1.choices[0].message.content =~ "function calls itself"

      # Second test with different IDs - replays from cassette!
      {:ok, response2} = ReqLLM.generate_text(
        "anthropic:claude-sonnet-4-20250514",
        "Explain recursion",
        conversation_id: "conv_xyz789",  # Different ID!
        req_http_options: [plug: plug]
      )

      assert response2.choices[0].message.content =~ "function calls itself"
    end
end
```

### Advanced: Template + Filter

Combine templates with filters for comprehensive LLM testing:

```elixir
test "LLM with API key filtering and ID templating" do
  with_cassette "llm_secure",
    [
      # Filter out API keys
      filter_request_headers: ["authorization", "x-api-key"],
      filter_sensitive_data: [
        {~r/sk-[a-zA-Z0-9]+/, "sk-REDACTED"}
      ],

      # Template dynamic IDs
      template: [
        patterns: [
          conversation_id: ~r/conv_[a-zA-Z0-9]+/,
          request_id: ~r/req_[a-zA-Z0-9]+/
        ]
      ]
    ],
    fn plug ->
      {:ok, response} = ReqLLM.generate_text(
        "anthropic:claude-sonnet-4-20250514",
        "Write a haiku",
        req_http_options: [
          plug: plug,
          headers: [{"x-api-key", "sk-secret123"}]
        ]
      )

      assert String.contains?(response.choices[0].message.content, "\n")
    end
end
```

**Benefits:**

- 🔒 API keys filtered (never saved)
- 🎯 IDs templated (works with any conversation)
- 💰 Save money (replay instead of calling API)
- ⚡ Fast tests (no network calls)

---

## Best Practices

### 1. Use Specific Patterns

```elixir
# ✅ Good - specific and clear
patterns: [
  product_sku: ~r/SKU-\d{6}/,
  order_id: ~r/ORD-\d{4}-\d{4}/
]

# ❌ Bad - too generic
patterns: [
  id: ~r/\d+/  # Matches everything!
]
```

### 2. Name Patterns Descriptively

```elixir
# ✅ Good names
patterns: [
  user_id: ~r/user-\d+/,
  product_sku: ~r/\d{4}-\d{4}/,
  session_token: ~r/sess_[a-zA-Z0-9]{32}/
]

# ❌ Bad names
patterns: [
  a: ~r/user-\d+/,
  thing: ~r/\d{4}-\d{4}/,
  x: ~r/sess_[a-zA-Z0-9]{32}/
]
```

### 3. Combine with Filters

Templates and filters work together:

```elixir
with_cassette "secure_api",
  [
    # Filters run FIRST (security)
    filter_request_headers: ["authorization"],
    filter_sensitive_data: [{~r/secret_\w+/, "REDACTED"}],

    # Then templates (flexibility)
    template: [
      patterns: [user_id: ~r/user-\d+/]
    ]
  ],
  fn plug ->
    # ...
  end
```

### 4. Use for Volatile Data

Great for data that changes frequently:

```elixir
# ✅ Good use cases
- Timestamps
- UUIDs
- Session tokens
- Conversation IDs
- Request IDs

# ❌ Poor use cases
- Static configuration
- Fixed API versions
- Constant product catalogs
```

### 5. Test Template Coverage

Ensure your patterns actually match:

```elixir
test "template pattern coverage" do
  # Record with one value
  with_cassette "coverage", [template: [patterns: [sku: ~r/\d{4}-\d{4}/]]], fn plug ->
    API.get_sku("1234-5678", plug: plug)
  end

  # Test with different value
  with_cassette "coverage", [template: [patterns: [sku: ~r/\d{4}-\d{4}/]]], fn plug ->
    result = API.get_sku("9999-8888", plug: plug)
    assert result.body["sku"] == "9999-8888"  # ✅ Verify substitution worked!
  end
end
```

---

## Limitations

### 1. Non-String JSON Values

Numbers, booleans, and null are **not templated**:

```elixir
# ❌ Won't work if count varies
%{"sku" => "1234-5678", "count" => 5}  # count stays literal

# If API returns different counts, you need separate cassettes
```

### 2. Binary Bodies

Blobs (images, PDFs, etc.) are not templated:

```elixir
# ❌ Cannot template binary data
%{"body_type" => "blob", "body_blob" => "..."}
```

### 3. Header Templating

Headers are **not** compared in template matching:

```elixir
# Headers ignored in template matching
# Use filter_request_headers to remove varying headers instead
```

### 4. Structure Must Match

Templates match **structure**, not values. Changing fields breaks matching:

```elixir
# Recorded: {"sku": "{{sku.0}}", "name": "Widget"}
# Replay: {"sku": "{{sku.0}}"}  ❌ Missing "name"!
```

### 5. Value Set Must Match

Since indexing is value-based, the **set of unique values** extracted must be
the same, though they can appear in any order or position:

```elixir
# Recording: "SKU 1111-2222 then 3333-4444"
# Unique values: ["1111-2222", "3333-4444"]
# Instance IDs: sku.0 = "1111-2222", sku.1 = "3333-4444"
# Template: "SKU {{sku.0}} then {{sku.1}}"

# Replay (different order): "SKU 3333-4444 then 1111-2222"
# Unique values: ["3333-4444", "1111-2222"]  # Same set!
# Instance IDs: sku.0 = "3333-4444", sku.1 = "1111-2222"
# Template: "SKU {{sku.0}} then {{sku.1}}"  ✅ Matches!
```

**This works** because template matching compares structure, not values.

**Won't work** if the unique value set changes:

```elixir
# Recording: "SKU 1111-2222 and 1111-2222"  # One unique value
# Template: "SKU {{sku.0}} and {{sku.0}}"

# Replay: "SKU 1111-2222 and 3333-4444"  # Two unique values
# Template: "SKU {{sku.0}} and {{sku.1}}"  ❌ Structure differs!
```

**Workaround:** Ensure replays use the same set of unique values as recording,
though order and repetition can vary.

---

## Summary

Templates enable **parameterized cassettes** for testing APIs with dynamic
values:

✅ **One cassette** handles multiple requests ✅ **Automatic extraction** via
regex patterns ✅ **Type-safe JSON** templating ✅ **Works with filters** for
security ✅ **Perfect for LLMs** with varying IDs ✅ **Detailed debugging** with
diffs

**Start simple:**

```elixir
with_cassette "my_test",
  [template: [patterns: [id: ~r/\d+/]]],
  fn plug ->
    # Your test here
  end
```

**Then optimize:**

- Add specific patterns
- Combine with filters
- Test with multiple values
- Read debug output when matching fails

Happy templating! 🎉
