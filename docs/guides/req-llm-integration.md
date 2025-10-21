# ReqLLM Integration with ReqCassette

This document explains how to use ReqCassette with ReqLLM to record and replay
LLM API calls, saving time and money during testing and development.

## Why Use ReqCassette with ReqLLM?

1. **Save Money** - LLM API calls cost money. Recording responses means you only
   pay once.
2. **Faster Tests** - Replaying from cassettes is instant vs waiting for API
   responses.
3. **Deterministic Tests** - Same input always gives same output (replayed from
   cassette).
4. **Offline Development** - Work without internet once cassettes are recorded.
5. **No Rate Limits** - Run tests as many times as you want without hitting API
   rate limits.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:req_llm, "~> 1.0.0-rc.7"},
    {:req_cassette, path: "."} # or from hex when published
  ]
end
```

## Basic Usage

### Simple Example

```elixir
model = "anthropic:claude-sonnet-4-20250514"
prompt = "Explain recursion in one sentence"

# First call - records to cassette
{:ok, response1} = ReqLLM.generate_text(
  model,
  prompt,
  max_tokens: 100,
  req_http_options: [
    plug: {ReqCassette.Plug, %{
      cassette_name: "llm_example",
      cassette_dir: "test/cassettes",
      mode: :record,
      filter_request_headers: ["authorization", "x-api-key", "cookie"]
    }}
  ]
)

# Second call - replays from cassette (FREE!)
{:ok, response2} = ReqLLM.generate_text(
  model,
  prompt,
  max_tokens: 100,
  req_http_options: [
    plug: {ReqCassette.Plug, %{
      cassette_name: "llm_example",
      cassette_dir: "test/cassettes",
      mode: :record,
      filter_request_headers: ["authorization", "x-api-key", "cookie"]
    }}
  ]
)

# Extract text from both responses
text1 = ReqLLM.Response.text(response1)
text2 = ReqLLM.Response.text(response2)
text1 == text2  # true - same response replayed!
```

### In Tests

```elixir
defmodule MyApp.LLMTest do
  use ExUnit.Case, async: true

  @cassette_dir "test/fixtures/llm_cassettes"

  setup do
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  test "generates code explanation" do
    {:ok, response} = ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "Explain what Elixir's pipe operator does",
      max_tokens: 150,
      req_http_options: [
        plug: {ReqCassette.Plug, %{
          cassette_name: "pipe_explanation",
          cassette_dir: @cassette_dir,
          mode: :record,
          filter_request_headers: ["authorization", "x-api-key", "cookie"]
        }}
      ]
    )

    explanation = ReqLLM.Response.text(response)
    assert explanation =~ ~r/pipe/i
    assert explanation =~ ~r/\|>/
  end
end
```

## Using Templates with ReqLLM

Templates are perfect for LLM APIs because they handle dynamic values like conversation IDs, message IDs, and timestamps. Instead of creating separate cassettes for each unique ID, **one cassette handles them all**.

### Why Use Templates with LLMs?

LLM APIs often include dynamic identifiers that change with every request:

- **Conversation IDs** - `conv_abc123`, `conv_xyz789`, etc.
- **Message IDs** - `msg_id_001`, `msg_id_002`, etc.
- **Request IDs** - `req_12345`, `req_67890`, etc.
- **Timestamps** - `2025-01-15T10:30:00Z`

Without templates, you'd need a separate cassette for each unique combination. With templates, **one cassette handles all variations**.

### Simple Example

```elixir
test "LLM chat with template for conversation IDs" do
  with_cassette "llm_chat",
    [
      template: [
        patterns: [
          conversation_id: ~r/conv_[a-zA-Z0-9]+/,
          message_id: ~r/msg_[a-zA-Z0-9]+/
        ]
      ]
    ],
    fn plug ->
      # First call - records with conv_abc123
      {:ok, response1} = ReqLLM.generate_text(
        "anthropic:claude-sonnet-4-20250514",
        "Explain recursion",
        conversation_id: "conv_abc123",
        req_http_options: [plug: plug]
      )

      assert response1.choices[0].message.content =~ "function calls itself"

      # Second call - replays with DIFFERENT ID using template!
      {:ok, response2} = ReqLLM.generate_text(
        "anthropic:claude-sonnet-4-20250514",
        "Explain recursion",
        conversation_id: "conv_xyz789",  # Different ID!
        req_http_options: [plug: plug]
      )

      # Same response, different ID substituted
      assert response2.choices[0].message.content =~ "function calls itself"
    end
end
```

**What happens:**

1. **Recording:** The first call records the real API response
2. **Templating:** `conv_abc123` is replaced with `{{conversation_id.0}}`
3. **Replay:** The second call matches the template structure and substitutes `conv_xyz789`

### Combining Filters and Templates

The real power comes from combining filtering (security) with templates (flexibility):

```elixir
@cassette_opts [
  # Security: Filter API keys
  filter_request_headers: ["authorization", "x-api-key"],

  # Flexibility: Template dynamic IDs
  template: [
    patterns: [
      conversation_id: ~r/conv_[a-zA-Z0-9]+/,
      request_id: ~r/req_[a-zA-Z0-9]+/,
      timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
    ]
  ]
]

test "secure and flexible LLM testing" do
  with_cassette "llm_secure_flexible", @cassette_opts, fn plug ->
    {:ok, response} = ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "Write a haiku",
      conversation_id: "conv_test_123",  # Will be templated
      req_http_options: [
        plug: plug,
        headers: [{"x-api-key", "sk-secret"}]  # Will be filtered
      ]
    )

    assert String.contains?(response.choices[0].message.content, "\n")
  end
end
```

**Benefits:**

- 🔒 **API keys filtered** - Never saved to cassettes
- 🎯 **IDs templated** - One cassette for all conversation IDs
- 💰 **Save money** - Replay instead of calling API repeatedly
- ⚡ **Fast tests** - No network calls during replay

### When to Use Templates

**Use templates when:**
- You have dynamic IDs (conversation, message, request, etc.)
- Timestamps change between test runs
- You want one cassette for multiple similar requests

**Don't use templates when:**
- Testing specific error scenarios with exact values
- API responses depend on the actual ID value
- You want exact value matching for debugging

**📖 For complete templating documentation**, patterns, and advanced use cases, see the [Templating Guide](templating.md).

## 🔒 Protecting API Keys

**Critical:** LLM APIs use Authorization headers containing sensitive API keys.
Always filter these headers to prevent secrets from being saved to cassettes.

### Why It's Important

```elixir
# ❌ WITHOUT FILTERING - API key saved to cassette!
with_cassette "llm_test", fn plug ->
  ReqLLM.generate_text("anthropic:claude-sonnet-4-20250514", "Hello", req_http_options: [plug: plug])
end

# Cassette file contains:
# "headers": {
#   "authorization": ["Bearer sk-ant-api03-YOUR_SECRET_KEY_HERE"]
# }
# ⚠️ If committed to git, your API key is exposed!
```

### The Solution

Always include `filter_request_headers` in your cassette options:

```elixir
# ✅ WITH FILTERING - API key protected!
with_cassette "llm_test",
  [filter_request_headers: ["authorization", "x-api-key", "cookie"]],
  fn plug ->
    ReqLLM.generate_text("anthropic:claude-sonnet-4-20250514", "Hello", req_http_options: [plug: plug])
  end

# Cassette does NOT contain authorization header ✅
```

### Recommended Pattern

```elixir
@cassette_opts [
  cassette_dir: "test/cassettes",
  mode: :record,
  filter_request_headers: ["authorization", "x-api-key", "cookie"]
]

test "LLM generation" do
  with_cassette "llm_test", @cassette_opts, fn plug ->
    {:ok, response} = ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "Explain Elixir",
      req_http_options: [plug: plug]
    )
    assert response.choices[0].message.content =~ "Elixir"
  end
end
```

**📖 For complete documentation** on protecting sensitive data, common patterns,
and best practices, see the
[Filtering Sensitive Data Guide](filtering.md).

## Recording Multiple API Calls (Agents)

The `:record` mode safely handles tests with multiple LLM API calls, such as
agents making tool calls or multi-turn conversations.

```elixir
# ✅ All agent interactions are saved
with_cassette "agent_conversation", fn plug ->
  {:ok, agent} = MyAgent.start_link(plug: plug)

  Agent.prompt(agent, "Hello")        # Cassette: [call 1]
  Agent.prompt(agent, "How are you?") # Cassette: [call 1, 2]
  Agent.prompt(agent, "Goodbye")      # Cassette: [call 1, 2, 3]
end
# Result: All 3 interactions saved ✅
```

### Best Practice: Environment Variables

Use environment variables to control recording:

```elixir
setup do
  mode = case System.get_env("CI") do
    "true" -> :replay  # CI always replays
    _ -> if System.get_env("RECORD"), do: :record, else: :replay
  end

  {:ok, cassette_mode: mode}
end

test "agent workflow", %{cassette_mode: mode} do
  with_cassette "agent_test", [mode: mode], fn plug ->
    # Your agent test here
  end
end
```

## How It Works

1. **First Request** (Recording):

   - ReqCassette intercepts the Req request to the LLM API
   - The request is forwarded to the actual API (costs money)
   - The response is saved to a JSON file (the "cassette")
   - The response is returned to your code

2. **Subsequent Requests** (Replay):
   - ReqCassette intercepts the request
   - It matches the request to a recorded cassette
   - The saved response is returned instantly (NO API call)
   - Your code gets the exact same response as before

## Cassette Matching

Cassettes are matched by creating an MD5 hash of:

- HTTP method (e.g., POST)
- URL path (e.g., `/v1/messages`)
- Query string
- **Request body** (the JSON payload containing your prompt)

This ensures that:

- ✅ Different prompts create different cassettes
- ✅ Same prompt replays from the same cassette
- ✅ Different parameters (max_tokens, temperature) create different cassettes

Example:

```elixir
# These create DIFFERENT cassettes (different prompts)
ReqLLM.generate_text(model, "Hello", max_tokens: 50)
ReqLLM.generate_text(model, "Goodbye", max_tokens: 50)

# These create DIFFERENT cassettes (different parameters)
ReqLLM.generate_text(model, "Hello", max_tokens: 50)
ReqLLM.generate_text(model, "Hello", max_tokens: 100)

# These use the SAME cassette (identical request)
ReqLLM.generate_text(model, "Hello", max_tokens: 50)
ReqLLM.generate_text(model, "Hello", max_tokens: 50)
```

## Configuration Options

The plug options are passed directly in your `Req` call:

```elixir
Req.get(url,
  plug: {ReqCassette.Plug, %{
    cassette_name: "my_api_call",    # Human-readable cassette name
    cassette_dir: "test/cassettes",  # Where to store cassettes
    mode: :record            # ✅ Default mode - safe for all tests
  }}
)
```

### Modes

**Available modes:**

- `:record` (default) - Records if cassette/interaction doesn't exist, replays
  if it does. Safely accumulates all interactions.
- `:replay` - Only replay from cassette, error if missing (great for CI)
- `:bypass` - Ignore cassettes entirely, always use network

## Examples

### Running the Demo

```bash
# With real API (requires ANTHROPIC_API_KEY)
ANTHROPIC_API_KEY=sk-... mix run examples/req_llm_demo.exs

# First run costs money, second run is free!
```

### Running the Tests

```bash
# Test with mocked LLM server (no API key needed)
mix test test/req_cassette/req_llm_test.exs

# Test with real API (requires API key, costs money - skipped by default)
ANTHROPIC_API_KEY=sk-... mix test --include req_llm
```

## Cassette File Format

Cassettes are stored as JSON files:

```json
{
  "status": 200,
  "headers": {
    "content-type": ["application/json"]
  },
  "body": "{\"id\":\"msg_123\",\"content\":[{\"type\":\"text\",\"text\":\"Hello!\"}],...}"
}
```

## Tips

1. **Commit cassettes to git** - They act as fixtures for your tests
2. **Use descriptive prompts** - Makes it easier to identify which cassette is
   which
3. **Delete cassettes to re-record** - When you want fresh responses
4. **Use :none mode in CI** - Ensures tests don't accidentally make API calls

## Gotchas

### Content-Type Header is Critical

The LLM API returns JSON with `content-type: application/json`. This header
**must** be preserved in the cassette, otherwise Req won't decode the JSON body
and you'll get strings instead of maps.

✅ **Good** - Response body is decoded:

```elixir
response.body["content"]  # Works!
```

❌ **Bad** - Missing content-type means body stays as string:

```elixir
response.body["content"]  # Error: binary doesn't support Access protocol
```

The fixed `ReqCassette.Plug` handles this correctly.

## Advanced: Agent with Tool Calling

The livebook includes `MyAgentWithCassettes`, a GenServer-based agent that
supports both tool calling and cassette recording/replay:

```elixir
# Start agent with cassette support
{:ok, agent} = MyAgentWithCassettes.start_link(
  cassette_opts: [
    cassette_name: "my_agent",
    cassette_dir: "agent_cassettes",
    mode: :record,  # ✅ Critical for agents!
    filter_request_headers: ["authorization", "x-api-key", "cookie"]
  ]
)

# First call - records to cassette (costs money)
MyAgentWithCassettes.prompt(agent, "What is 15 * 7?")

# Second call - replays from cassette (FREE!)
MyAgentWithCassettes.prompt(agent, "What is 15 * 7?")
```

The agent:

- Uses non-streaming responses (required for cassettes)
- Supports tool calling (calculator, web search)
- Maintains conversation history
- Records both initial LLM calls and tool follow-ups

## Streaming Support

ReqLLM supports streaming, but cassettes currently only work with non-streaming
responses. For streaming:

```elixir
# This won't work with cassettes
{:ok, stream} = ReqLLM.stream_text(model, prompt)
```

Use regular `generate_text/3` for cassette support. The livebook includes both:

- `MyAgent` - Streaming version (no cassettes)
- `MyAgentWithCassettes` - Non-streaming version (with cassettes)

## Troubleshooting

### "FunctionClauseError: no function clause matching in Access.get/3"

This means the response body is a string instead of a decoded map.

**Cause**: Missing `content-type` header in cassette.

**Fix**: Delete the cassette and re-record with the fixed `ReqCassette.Plug`.

### Tests are slow

Make sure cassettes are being replayed, not re-recorded each time:

```elixir
# Check cassette directory
IO.inspect(File.ls!("test/cassettes"))

# Should show .json files
```

### Different response each time

If the cassette matching isn't working, check that your request parameters are
identical:

```elixir
# These will create DIFFERENT cassettes
ReqLLM.generate_text(model, "Hello", max_tokens: 50)
ReqLLM.generate_text(model, "Hello", max_tokens: 100)  # Different max_tokens!
```

## Next Steps

- See `lib/req_cassette/plug.ex` for the implementation
- See `test/req_cassette/req_llm_test.exs` for test examples
- See `livebooks/req_llm.livemd` for interactive examples with agents

## Contributing

Found a bug? Have an idea? Open an issue or PR!
