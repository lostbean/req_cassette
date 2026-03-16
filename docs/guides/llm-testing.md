# Testing LLM Applications with ReqCassette

> **Record once, replay forever** - Save money and speed up your LLM tests

Testing LLM-powered applications presents unique challenges: API calls are expensive,
responses are slow, and dynamic IDs make cassette matching difficult. ReqCassette's
template feature solves these problems with built-in presets for popular LLM providers.

## Table of Contents

- [Why LLM APIs Need Special Handling](#why-llm-apis-need-special-handling)
- [Quick Start](#quick-start)
- [Provider-Specific Patterns](#provider-specific-patterns)
- [Multi-Turn Conversations](#multi-turn-conversations)
- [Tool Calling & Function Calls](#tool-calling--function-calls)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

---

## Why LLM APIs Need Special Handling

LLM APIs generate dynamic identifiers that change with every request:

| Provider | Dynamic Values | Example |
|----------|----------------|---------|
| Anthropic | `msg_*`, `toolu_*`, `req_*` | `msg_01XzW7o3s58J6KauMpLBFtEf` |
| OpenAI | `chatcmpl-*`, `call_*` | `chatcmpl-abc123def456` |
| All | timestamps, request IDs | `2025-01-15T10:30:00Z` |

Without templates, you'd need separate cassettes for each unique ID combination.

### The Problem

```elixir
# First test run - records with msg_abc123
{:ok, response1} = ReqLLM.generate_text("anthropic:claude-sonnet-4-20250514", "Hello")
# response1.id = "msg_abc123"

# Second test run - different ID, cassette doesn't match!
{:ok, response2} = ReqLLM.generate_text("anthropic:claude-sonnet-4-20250514", "Hello")
# Fails! Server returns "msg_xyz789" but cassette expects "msg_abc123"
```

### The Solution

```elixir
with_cassette "llm_test",
  [
    filter_request_headers: ["authorization"],  # Security!
    template: [preset: :anthropic]              # Handle dynamic IDs
  ],
  fn plug ->
    {:ok, response} = ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "Hello",
      req_http_options: [plug: plug]
    )
    # Works with ANY message ID - template handles substitution!
  end
```

---

## Quick Start

### 1. Install Dependencies

```elixir
# mix.exs
def deps do
  [
    {:req_llm, "~> 1.0.0-rc.7"},
    {:req_cassette, "~> 0.4.0"}
  ]
end
```

### 2. Configure Test Helper

```elixir
# test/support/cassette_case.ex
defmodule MyApp.CassetteCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import ReqCassette

      @cassette_dir "test/fixtures/cassettes"
      @llm_opts [
        cassette_dir: @cassette_dir,
        filter_request_headers: ["authorization", "x-api-key"],
        template: [preset: :anthropic]
      ]
    end
  end
end
```

### 3. Write Your First LLM Test

```elixir
defmodule MyApp.LLMTest do
  use MyApp.CassetteCase, async: true

  test "generates helpful response" do
    with_cassette "helpful_response", @llm_opts, fn plug ->
      {:ok, response} = ReqLLM.generate_text(
        "anthropic:claude-sonnet-4-20250514",
        "Explain recursion in one sentence",
        max_tokens: 100,
        req_http_options: [plug: plug]
      )

      assert ReqLLM.Response.text(response) =~ "function"
    end
  end
end
```

---

## Provider-Specific Patterns

### Anthropic (Claude)

```elixir
# Using preset (recommended)
template: [preset: :anthropic]

# Manual patterns (equivalent)
template: [
  patterns: [
    msg_id: ~r/msg_[a-zA-Z0-9]+/,
    toolu_id: ~r/toolu_[a-zA-Z0-9]+/,
    anthropic_request_id: ~r/req_[a-zA-Z0-9]+/
  ]
]
```

**Anthropic Response Structure:**

```json
{
  "id": "msg_01XzW7...",           // <-- Templated as {{msg_id.0}}
  "type": "message",
  "content": [
    {"type": "text", "text": "..."},
    {"type": "tool_use", "id": "toolu_01K6u2...", ...}  // <-- Templated as {{toolu_id.0}}
  ]
}
```

### OpenAI

```elixir
# Using preset (recommended)
template: [preset: :openai]

# Manual patterns (equivalent)
template: [
  patterns: [
    chatcmpl_id: ~r/chatcmpl-[a-zA-Z0-9]+/,
    call_id: ~r/call_[a-zA-Z0-9]+/
  ]
]
```

### Combined (Multiple Providers)

If your application uses multiple LLM providers:

```elixir
# All LLM patterns combined
template: [preset: :llm]
```

### Common Patterns (UUIDs, Timestamps)

For domain-specific dynamic values:

```elixir
template: [preset: :common]

# Includes:
# - uuid: Standard UUID v4 format
# - iso_timestamp: ISO 8601 datetime format
```

### Combining Presets with Custom Patterns

```elixir
template: [
  preset: :anthropic,
  patterns: [
    # Custom patterns override/extend preset
    order_id: ~r/ORD-\d+/,
    session_id: ~r/sess_[a-zA-Z0-9]+/
  ]
]
```

---

## Multi-Turn Conversations

### Recording Multiple Turns

```elixir
test "multi-turn conversation" do
  with_cassette "chat_turns", @llm_opts, fn plug ->
    opts = [req_http_options: [plug: plug]]

    # Turn 1: Initial question
    {:ok, r1} = ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "What is 2+2?",
      opts
    )
    assert ReqLLM.Response.text(r1) =~ "4"

    # Turn 2: Follow-up using conversation history
    {:ok, r2} = ReqLLM.chat(
      "anthropic:claude-sonnet-4-20250514",
      [
        %{role: "user", content: "What is 2+2?"},
        %{role: "assistant", content: ReqLLM.Response.text(r1)},
        %{role: "user", content: "Now multiply that by 3"}
      ],
      opts
    )
    assert ReqLLM.Response.text(r2) =~ "12"
  end
end
```

### Conversation History with Tool Use

The template system handles `tool_use_id` appearing in both the assistant's
response and your subsequent request:

```elixir
# Assistant response contains:
#   {"type": "tool_use", "id": "toolu_abc123", ...}
#
# Your next request contains:
#   {"type": "tool_result", "tool_use_id": "toolu_abc123", ...}
#
# Both are templated as {{toolu_id.0}} and matched/substituted together
```

---

## Tool Calling & Function Calls

### Anthropic Tool Use Workflow

```elixir
test "tool calling workflow" do
  with_cassette "calculator_tool", @llm_opts, fn plug ->
    tools = [
      %{
        name: "calculator",
        description: "Performs arithmetic calculations",
        input_schema: %{
          type: "object",
          properties: %{
            expression: %{type: "string", description: "Math expression to evaluate"}
          },
          required: ["expression"]
        }
      }
    ]
    opts = [tools: tools, req_http_options: [plug: plug]]

    # Step 1: Model decides to use a tool
    {:ok, r1} = ReqLLM.chat(
      "anthropic:claude-sonnet-4-20250514",
      [%{role: "user", content: "Calculate 15 * 7"}],
      opts
    )

    # Extract tool use from response
    tool_use = Enum.find(r1.content, &(&1["type"] == "tool_use"))
    assert tool_use["name"] == "calculator"

    # Step 2: Execute tool and return result
    # (tool_use["id"] is templated - same value used in both request and response)
    result = eval_expression(tool_use["input"]["expression"])

    {:ok, r2} = ReqLLM.chat(
      "anthropic:claude-sonnet-4-20250514",
      [
        %{role: "user", content: "Calculate 15 * 7"},
        %{role: "assistant", content: r1.content},
        %{role: "user", content: [
          %{
            type: "tool_result",
            tool_use_id: tool_use["id"],  # Same ID from response
            content: to_string(result)
          }
        ]}
      ],
      opts
    )

    # Model incorporates tool result in final response
    assert ReqLLM.Response.text(r2) =~ "105"
  end
end

defp eval_expression(expr) do
  {result, _} = Code.eval_string(expr)
  result
end
```

### Why This Works

1. **Recording**: The `toolu_id` (`toolu_abc123`) is extracted from the response
2. **Templating**: Both response (`"id": "toolu_abc123"`) and subsequent request
   (`"tool_use_id": "toolu_abc123"`) are templated as `{{toolu_id.0}}`
3. **Replay**: When replaying with a different ID, both locations are substituted
   consistently

---

## Best Practices

### 1. Always Filter Authorization Headers

```elixir
# CRITICAL: Never commit API keys to cassettes!
filter_request_headers: ["authorization", "x-api-key", "cookie"]
```

### 2. Use Presets for Simplicity

```elixir
# Good - simple and maintainable
template: [preset: :anthropic]

# Also good - when you need custom patterns
template: [preset: :anthropic, patterns: [custom_id: ~r/my_pattern/]]
```

### 3. Separate Cassettes by Scenario

```elixir
# Good - clear purpose, easy to debug
with_cassette "llm_simple_question", ...
with_cassette "llm_tool_calling", ...
with_cassette "llm_error_handling", ...
with_cassette "llm_streaming", ...

# Bad - unclear what this tests
with_cassette "llm_test_1", ...
```

### 4. Use Replay Mode in CI

```elixir
# In CI, ensure cassettes exist - don't hit real APIs
mode: :replay
```

### 5. Enable Debug Mode When Troubleshooting

```elixir
template: [preset: :anthropic, debug: true]
# Logs extraction and matching details
```

### 6. Set Timeouts for Slow LLM Responses

LLM APIs can take 20-60+ seconds for large prompts (especially with tool calling).
By default, the outbound request during recording uses Req's 15-second timeout.
Use `req_options` to increase it:

```elixir
# Increase timeout for slow LLM responses
with_cassette "large_prompt",
  [
    filter_request_headers: ["authorization"],
    template: [preset: :anthropic],
    req_options: [receive_timeout: 120_000]  # 2 minutes
  ],
  fn plug ->
    ReqLLM.generate_text("anthropic:claude-sonnet-4-20250514", large_prompt,
      req_http_options: [plug: plug]
    )
  end
```

### 7. Consider Test Organization

```elixir
# test/support/cassette_case.ex
defmodule MyApp.CassetteCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import ReqCassette

      @cassette_dir "test/fixtures/cassettes"

      def llm_cassette_opts(extra_opts \\ []) do
        [
          cassette_dir: @cassette_dir,
          filter_request_headers: ["authorization", "x-api-key"],
          template: [preset: :llm],
          req_options: [receive_timeout: 120_000]
        ] ++ extra_opts
      end
    end
  end
end
```

---

## Troubleshooting

### "Network request failed" / timeout during recording

**Cause:** LLM responses take longer than Req's default 15-second `receive_timeout`.
This is common with large prompts, tool-calling workflows, or complex multi-schema inputs.

**Solution:**
```elixir
with_cassette "slow_api",
  [req_options: [receive_timeout: 120_000]],
  fn plug ->
    # ...
  end
```

### "No matching interaction found"

**Cause:** Template structure changed between recording and replay.

**Diagnosis:**
```elixir
# Enable debug mode to see what's different
template: [preset: :anthropic, debug: true]
```

**Solutions:**
1. Delete the cassette and re-record
2. Check that patterns match all dynamic values in the request
3. Verify the request body structure hasn't changed

### "API key exposed in cassette"

**Cause:** Missing `filter_request_headers`.

**Solution:**
```elixir
# Always include authorization filtering
filter_request_headers: ["authorization", "x-api-key", "cookie"]
```

**Fix existing cassette:**
1. Delete the compromised cassette
2. Rotate your API key immediately
3. Re-record with proper filtering

### "Tests pass locally but fail in CI"

**Cause:** Cassettes not committed or mode mismatch.

**Solutions:**
1. Ensure cassettes are committed to version control
2. Use `mode: :replay` in CI to catch missing cassettes early
3. Check `.gitignore` doesn't exclude cassette directory

### "Pattern not matching expected values"

**Cause:** Pattern regex doesn't match the actual ID format.

**Diagnosis:**
```elixir
# Check the actual ID format in the cassette file
cat test/fixtures/cassettes/my_test.json | grep -o '"id": "[^"]*"'

# Test your pattern
Regex.match?(~r/msg_[a-zA-Z0-9]+/, "msg_01XzW7o3s58J6KauMpLBFtEf")
```

**Solution:**
```elixir
# Use broader patterns if IDs vary in length
patterns: [
  msg_id: ~r/msg_[a-zA-Z0-9]+/,  # + allows any length
]
```

### "Template variables not being substituted in response"

**Cause:** The variable only appears in the response, not the request.

**Explanation:** Template variables must appear in BOTH the request AND the response
to be substituted. This is by design - it ensures the variable represents something
that flows through the request/response cycle.

**Solution:** If you need response-only templating, the current design expects the
variable to first appear in a request (even if in a subsequent request in a
multi-turn conversation).

### Inspecting Cassette Contents

Use the Mix task to analyze cassettes:

```bash
$ mix req_cassette.inspect test/fixtures/cassettes/my_test.json

Cassette: test/fixtures/cassettes/my_test.json
Version: 2.0
Interactions: 2

Interaction #1
  Template: ENABLED
  Patterns: msg_id, toolu_id
  Recorded Values:
    msg_id.0 = "msg_01XzW7o3s58J6KauMpLBFtEf"
    toolu_id.0 = "toolu_01K6u2Q9D6W7heeVvKAcLcAJ"
  Request: POST https://api.anthropic.com/v1/messages
  Response: 200 OK
```

---

## Available Presets Reference

| Preset | Patterns | Use Case |
|--------|----------|----------|
| `:anthropic` | `msg_id`, `toolu_id`, `anthropic_request_id` | Anthropic Claude API |
| `:openai` | `chatcmpl_id`, `call_id` | OpenAI API |
| `:llm` | All above combined | Multi-provider applications |
| `:common` | `uuid`, `iso_timestamp` | General dynamic values |

See `ReqCassette.Template.Presets` documentation for full pattern details.
