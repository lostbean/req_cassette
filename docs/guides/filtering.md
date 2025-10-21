# Sensitive Data Filtering Guide

A comprehensive guide to protecting sensitive information in ReqCassette
recordings.

## Table of Contents

- [Why Filter Sensitive Data?](#why-filter-sensitive-data)
- [Quick Start](#quick-start)
- [Filtering Methods](#filtering-methods)
  - [1. Header Filtering](#1-header-filtering)
  - [2. Regex Pattern Filtering](#2-regex-pattern-filtering)
  - [3. Request Callback Filtering](#3-request-callback-filtering)
  - [4. Response Callback Filtering](#4-response-callback-filtering)
- [LLM API Protection](#llm-api-protection)
- [Common Patterns](#common-patterns)
- [Complete Examples](#complete-examples)
- [Verification](#verification)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Why Filter Sensitive Data?

Cassettes record real HTTP interactions, which often contain sensitive
information:

- **API Keys** - In query strings, headers, or request bodies
- **Authentication Tokens** - Bearer tokens, session tokens, OAuth tokens
- **Credentials** - Passwords, secret keys, certificates
- **Personal Data** - Emails, names, addresses, phone numbers
- **Internal Information** - Infrastructure details, internal URLs

**The Risk:** If cassettes are committed to version control without filtering,
sensitive data becomes permanently embedded in your repository's history,
potentially exposing it to:

- Public repositories on GitHub/GitLab
- Unauthorized team members
- Security breaches through compromised accounts
- Automated secret scanners

**The Solution:** ReqCassette provides comprehensive filtering to remove or
redact sensitive data **before** cassettes are written to disk.

## Quick Start

For LLM APIs (Anthropic, OpenAI, etc.), always filter authorization headers:

```elixir
with_cassette "my_llm_test",
  [filter_request_headers: ["authorization", "x-api-key", "cookie"]],
  fn plug ->
    ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "Hello!",
      req_http_options: [plug: plug]
    )
  end
```

This prevents API keys in `Authorization: Bearer sk-ant-...` headers from being
saved.

## Filtering Methods

ReqCassette supports four complementary filtering approaches, applied in this
order:

1. **Regex filters** - Pattern-based replacement
2. **Header filters** - Remove specific headers
3. **Request callback** (`filter_request`) - Request-only custom filtering
4. **Response callback** (`filter_response`) - Response-only custom filtering
   (always safe!)

### 1. Header Filtering

Remove sensitive headers entirely from requests and responses.

**When to use:** When headers contain secrets you never want to save (API keys,
session cookies, auth tokens).

```elixir
with_cassette "api_test",
  [
    filter_request_headers: ["authorization", "x-api-key", "cookie"],
    filter_response_headers: ["set-cookie", "x-session-token"]
  ],
  fn plug ->
    Req.get!(
      "https://api.example.com/data",
      headers: [{"authorization", "Bearer secret-token"}],
      plug: plug
    )
  end
```

**Features:**

- Case-insensitive matching (`Authorization` matches `authorization`)
- Completely removes headers from cassette
- Separate lists for request and response headers
- Headers are never written to disk

**Result:** Cassette will not contain the specified headers at all.

### 2. Regex Pattern Filtering

Replace matching patterns with redacted values using regular expressions.

**When to use:** For secrets embedded in URLs, query strings, or
request/response bodies.

```elixir
with_cassette "api_test",
  [
    filter_sensitive_data: [
      {~r/api_key=[\w-]+/, "api_key=<REDACTED>"},
      {~r/"token":"[^"]+"/, ~s("token":"<REDACTED>")},
      {~r/Bearer [\w.-]+/, "Bearer <REDACTED>"}
    ]
  ],
  fn plug ->
    Req.get!("https://api.example.com/data?api_key=secret123", plug: plug)
  end
```

**Features:**

- Applied to URIs, query strings, and all body types (text, JSON, blob)
- Multiple patterns processed in order
- Works with JSON bodies (pattern matching on serialized form + recursive)
- Supports binary/blob bodies (base64-decoded, filtered, re-encoded)

**Result:** Cassette contains the URL
`https://api.example.com/data?api_key=<REDACTED>`

### 3. Request Callback Filtering

Custom filtering for requests with complex logic.

**When to use:** For complex request transformations, normalization, or
conditional filtering based on request data.

```elixir
with_cassette "api_test",
  [
    filter_request: fn request ->
      request
      |> update_in(["body_json", "email"], fn _ -> "user@example.com" end)
      |> update_in(["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
    end
  ],
  fn plug ->
    Req.post!(
      "https://api.example.com/events",
      json: %{event: "login", timestamp: DateTime.utc_now(), email: "alice@real.com"},
      plug: plug
    )
  end
```

**Features:**

- Applied during BOTH recording and matching (like regex/header filters)
- Only receives request portion of interaction
- Safe for complex request transformations
- Cannot break replay if used correctly

**⚠️ Important:** If `filter_request` modifies fields used for matching (method,
uri, query, headers, body), ensure transformations are idempotent or adjust
`match_requests_on` to exclude those fields.

**Request structure:**

```elixir
%{
  "method" => "POST",
  "uri" => "https://...",
  "query_string" => "...",
  "headers" => %{},
  "body_type" => "json",
  "body_json" => %{}  # or "body" for text, "body_blob" for binary
}
```

### 4. Response Callback Filtering

Custom filtering for responses - always safe!

**When to use:** For complex response transformations, redaction, or conditional
filtering based on response data.

```elixir
with_cassette "api_test",
  [
    filter_response: fn response ->
      response
      |> update_in(["body_json", "password"], fn _ -> "<REDACTED>" end)
      |> update_in(["body_json", "email"], fn _ -> "user@example.com" end)
      |> put_in(["headers", "x-secret"], ["<REDACTED>"])
    end
  ],
  fn plug ->
    Req.post!(
      "https://api.example.com/users",
      json: %{email: "alice@real.com", password: "secret"},
      plug: plug
    )
  end
```

**Features:**

- Applied ONLY during recording
- Only receives response portion of interaction
- Always safe - responses don't affect matching
- Simplest callback type for response filtering

**Response structure:**

```elixir
%{
  "status" => 200,
  "headers" => %{},
  "body_type" => "json",
  "body_json" => %{}  # or "body" for text, "body_blob" for binary
}
```

## LLM API Protection

LLM APIs use Authorization headers with sensitive API keys. **Always filter
these headers** when using ReqCassette with LLM services.

### Why It's Critical for LLMs

```elixir
# ❌ WITHOUT FILTERING - API key saved to cassette!
with_cassette "llm_test", fn plug ->
  ReqLLM.generate_text(
    "anthropic:claude-sonnet-4-20250514",
    "Hello",
    req_http_options: [plug: plug]
  )
end

# Cassette contains:
# "headers": {
#   "authorization": ["Bearer sk-ant-api03-YOUR_SECRET_KEY_HERE"]
# }
```

```elixir
# ✅ WITH FILTERING - API key protected!
with_cassette "llm_test",
  [filter_request_headers: ["authorization", "x-api-key", "cookie"]],
  fn plug ->
    ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "Hello",
      req_http_options: [plug: plug]
    )
  end

# Cassette does NOT contain authorization header
```

### Recommended Pattern for LLM Tests

```elixir
defmodule MyApp.LLMTest do
  use ExUnit.Case, async: true

  @cassette_dir "test/cassettes/llm"
  @cassette_opts [
    cassette_dir: @cassette_dir,
    mode: :record,
    filter_request_headers: ["authorization", "x-api-key", "cookie"]
  ]

  test "generates response" do
    with_cassette "llm_generation", @cassette_opts, fn plug ->
      {:ok, response} = ReqLLM.generate_text(
        "anthropic:claude-sonnet-4-20250514",
        "Explain Elixir",
        max_tokens: 100,
        req_http_options: [plug: plug]
      )

      assert response.choices[0].message.content =~ "Elixir"
    end
  end
end
```

### Agent/Multi-Turn Protection

For agents making multiple LLM calls:

```elixir
{:ok, agent} = MyAgent.start_link(
  cassette_opts: [
    cassette_name: "my_agent",
    cassette_dir: "test/cassettes",
    mode: :record,
    filter_request_headers: ["authorization", "x-api-key", "cookie"]
  ]
)

MyAgent.prompt(agent, "What is 15 * 7?")
```

## Common Patterns

### API Keys (Query Parameters)

```elixir
filter_sensitive_data: [
  {~r/api_key=[\w-]+/, "api_key=<REDACTED>"},
  {~r/access_token=[\w-]+/, "access_token=<REDACTED>"}
]
```

### API Keys (JSON Bodies)

```elixir
filter_sensitive_data: [
  {~r/"apiKey":"[^"]+"/, ~s("apiKey":"<REDACTED>")},
  {~r/"api_key":"[^"]+"/, ~s("api_key":"<REDACTED>")}
]
```

### Bearer Tokens

```elixir
filter_sensitive_data: [
  {~r/Bearer [\w.-]+/, "Bearer <REDACTED>"}
]
```

### OAuth Tokens

```elixir
filter_sensitive_data: [
  {~r/"access_token":"[^"]+"/, ~s("access_token":"<REDACTED>")},
  {~r/"refresh_token":"[^"]+"/, ~s("refresh_token":"<REDACTED>")}
]
```

### Email Addresses

```elixir
filter_sensitive_data: [
  {~r/[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}/, "user@example.com"}
]
```

### Credit Card Numbers

```elixir
filter_sensitive_data: [
  {~r/\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}/, "XXXX-XXXX-XXXX-XXXX"}
]
```

### UUIDs (for deterministic cassettes)

```elixir
filter_sensitive_data: [
  {~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/,
   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
]
```

### Timestamps (for deterministic cassettes)

```elixir
filter_sensitive_data: [
  {~r/"timestamp":"[^"]+"/, ~s("timestamp":"<NORMALIZED>")},
  {~r/"created_at":"[^"]+"/, ~s("created_at":"<NORMALIZED>")}
]
```

## Complete Examples

### Basic Authentication API

```elixir
with_cassette "auth_api",
  [
    filter_request_headers: ["authorization"],
    filter_response_headers: ["set-cookie"],
    filter_sensitive_data: [
      {~r/password=[\w-]+/, "password=<REDACTED>"}
    ]
  ],
  fn plug ->
    Req.post!(
      "https://api.example.com/login?password=secret",
      headers: [{"authorization", "Basic dXNlcjpwYXNz"}],
      plug: plug
    )
  end
```

### Payment API with Multiple Secrets

```elixir
with_cassette "payment_api",
  [
    filter_request_headers: ["authorization", "x-api-key"],
    filter_sensitive_data: [
      # Credit cards
      {~r/\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}/, "XXXX-XXXX-XXXX-XXXX"},
      # CVV
      {~r/"cvv":"\d{3,4}"/, ~s("cvv":"XXX")},
      # SSN
      {~r/\d{3}-\d{2}-\d{4}/, "XXX-XX-XXXX"}
    ],
    # Redact customer email in request
    filter_request: fn request ->
      update_in(
        request,
        ["body_json", "customer", "email"],
        fn _ -> "customer@example.com" end
      )
    end
  ],
  fn plug ->
    Req.post!(
      "https://api.stripe.com/v1/charges",
      json: %{
        amount: 1000,
        card: %{number: "4242424242424242", cvv: "123"},
        customer: %{email: "alice@real.com", ssn: "123-45-6789"}
      },
      headers: [{"authorization", "Bearer sk_test_secret"}],
      plug: plug
    )
  end
```

### LLM with Full Protection

```elixir
with_cassette "llm_protected",
  [
    mode: :record,
    filter_request_headers: ["authorization", "x-api-key", "cookie"],
    filter_sensitive_data: [
      # Normalize timestamps for deterministic cassettes
      {~r/"timestamp":"[^"]+"/, ~s("timestamp":"<NORMALIZED>")},
      # Normalize request IDs
      {~r/"request_id":"[^"]+"/, ~s("request_id":"<NORMALIZED>")}
    ],
    # Normalize request fields
    filter_request: fn request ->
      update_in(request, ["body_json", "created_at"], fn _ -> "<NORMALIZED>" end)
    end,
    # Normalize response fields
    filter_response: fn response ->
      response
      |> put_in(["headers", "x-request-id"], ["<NORMALIZED>"])
      |> put_in(["body_json", "id"], "<NORMALIZED>")
    end
  ],
  fn plug ->
    {:ok, response} = ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "Hello!",
      max_tokens: 100,
      req_http_options: [plug: plug]
    )

    assert response.choices[0].message.content =~ "Hello"
  end
```

## Verification

### Verify Cassettes Are Properly Filtered

After recording, check cassettes for leaked secrets:

```bash
# Search for common secret patterns
grep -r "Bearer" test/cassettes/
grep -r "api_key=" test/cassettes/
grep -r "password" test/cassettes/

# Check specific cassette
cat test/cassettes/my_test.json | grep -i "authorization"
```

### Programmatic Verification

```elixir
test "cassette does not contain secrets" do
  cassette_path = "test/cassettes/my_test.json"
  {:ok, content} = File.read(cassette_path)

  # Verify secrets are redacted
  refute String.contains?(content, "sk-ant-")  # Anthropic API key
  refute String.contains?(content, "Bearer sk_")  # Generic bearer token
  refute String.contains?(content, "my-secret-key")

  # Verify redaction markers are present
  assert String.contains?(content, "<REDACTED>")
end
```

### Check Cassette Structure

```elixir
test "cassette has properly filtered headers" do
  cassette_path = "test/cassettes/my_test.json"
  {:ok, data} = File.read(cassette_path)
  {:ok, cassette} = Jason.decode(data)

  interaction = hd(cassette["interactions"])

  # Request headers should not include authorization
  request_headers = interaction["request"]["headers"]
  refute Map.has_key?(request_headers, "authorization")
  refute Map.has_key?(request_headers, "x-api-key")

  # Response headers should not include cookies
  response_headers = interaction["response"]["headers"]
  refute Map.has_key?(response_headers, "set-cookie")
end
```

## Best Practices

### 1. Filter by Default

Create a module-level constant for common filter options:

```elixir
defmodule MyApp.APITest do
  use ExUnit.Case, async: true

  @cassette_opts [
    cassette_dir: "test/cassettes",
    mode: :record,
    filter_request_headers: ["authorization", "x-api-key", "cookie"],
    filter_response_headers: ["set-cookie"]
  ]

  test "API call" do
    with_cassette "my_test", @cassette_opts, fn plug ->
      # Your test code
    end
  end
end
```

### 2. Use Environment-Based Recording

```elixir
setup do
  mode = case System.get_env("CI") do
    "true" -> :replay  # CI always replays (no API keys needed)
    _ -> if System.get_env("RECORD"), do: :record, else: :replay
  end

  cassette_opts = [
    cassette_dir: "test/cassettes",
    mode: mode,
    filter_request_headers: ["authorization", "x-api-key", "cookie"]
  ]

  {:ok, cassette_opts: cassette_opts}
end
```

### 3. Document Required Filtering

Add comments to remind future developers:

```elixir
# IMPORTANT: Always filter authorization headers for LLM APIs
# to prevent API keys from being committed to version control
with_cassette "llm_test",
  [filter_request_headers: ["authorization", "x-api-key", "cookie"]],
  fn plug ->
    # ...
  end
```

### 4. Test Filtered Cassettes

Add tests to verify filtering is working:

```elixir
describe "cassette security" do
  test "cassettes do not contain API keys" do
    cassettes_dir = "test/cassettes"

    cassettes_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.each(fn filename ->
      content = File.read!(Path.join(cassettes_dir, filename))

      # Add your secret patterns here
      refute String.contains?(content, "sk-ant-"),
             "#{filename} contains Anthropic API key"
      refute String.contains?(content, "sk-test-"),
             "#{filename} contains Stripe API key"
    end)
  end
end
```

### 5. Audit Before Committing

Before committing cassettes to git:

```bash
# Quick audit script
for file in test/cassettes/*.json; do
  echo "Checking $file..."
  grep -E "(sk-|Bearer|password|token|api_key)" "$file" && echo "⚠️  SECRETS FOUND!" || echo "✅ Clean"
done
```

### 6. Use .gitignore for Unfiltered Cassettes

If you want to record without filtering locally but never commit:

```gitignore
# .gitignore
test/cassettes/unfiltered/
```

Then use:

```elixir
with_cassette "debug_test",
  [cassette_dir: "test/cassettes/unfiltered"],
  fn plug ->
    # Test without filtering for debugging
  end
```

## Summary

**Essential Filtering for LLM APIs:**

```elixir
filter_request_headers: ["authorization", "x-api-key", "cookie"]
```

**Comprehensive Protection:**

```elixir
with_cassette "secure_test",
  [
    # Remove auth headers
    filter_request_headers: ["authorization", "x-api-key", "cookie"],
    filter_response_headers: ["set-cookie"],

    # Redact patterns
    filter_sensitive_data: [
      {~r/api_key=[\w-]+/, "api_key=<REDACTED>"},
      {~r/"token":"[^"]+"/, ~s("token":"<REDACTED>")}
    ],

    # Request filtering (normalization)
    filter_request: fn request ->
      update_in(request, ["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
    end,

    # Response filtering (redaction)
    filter_response: fn response ->
      update_in(response, ["body_json", "email"], fn _ -> "user@example.com" end)
    end
  ],
  fn plug ->
    # Your code here
  end
```

**Remember:**

1. Filter authorization headers for ALL LLM APIs
2. Use `filter_response` for response-only filtering (always safe!)
3. Use `filter_request` for request normalization (timestamps, IDs)
4. Test cassettes for leaked secrets before committing
5. Use environment variables to control recording modes
6. Default to `:record` mode with filtering enabled

For more examples, see:

- [ReqLLM Integration Guide](req-llm-integration.md)
- [Filter module documentation](../lib/req_cassette/filter.ex)
- [Example tests](../test/req_cassette/filter_test.exs)
