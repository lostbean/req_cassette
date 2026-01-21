# ReqCassette

[![Hex.pm](https://img.shields.io/hexpm/v/req_cassette.svg)](https://hex.pm/packages/req_cassette)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/req_cassette/)
[![GitHub CI](https://github.com/lostbean/req_cassette/workflows/CI/badge.svg)](https://github.com/lostbean/req_cassette/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> **⚠️ Upgrading?** See migration guides for breaking changes:
>
> - [v0.4 → v0.5](docs/MIGRATION_V0.4_TO_V0.5.md) - Cross-process session
>   support
> - [v0.1 → v0.2](docs/MIGRATION_V0.1_TO_V0.2.md) - API changes from v0.1

A VCR-style record-and-replay library for Elixir's [Req](https://hexdocs.pm/req)
HTTP client. Record HTTP responses to "cassettes" and replay them in tests for
fast, deterministic, offline-capable testing.

Perfect for testing applications that use external APIs, especially LLM APIs
like Anthropic's Claude!

## Features

- 🎬 **Record & Replay** - Capture real HTTP responses and replay them instantly
- ⚡ **Async-Safe** - Works with `async: true` in ExUnit (unlike ExVCR)
- 🔌 **Built on Req.Test** - Uses Req's native testing infrastructure (no global
  mocking)
- 🤖 **ReqLLM Integration** - Perfect for testing LLM applications (save money
  on API calls!)
- 📝 **Human-Readable** - Pretty-printed JSON cassettes with native JSON objects
- 🎯 **Simple API** - Use `with_cassette` for clean, functional testing
- 🔒 **Sensitive Data Filtering** - Built-in support for redacting secrets
- 🎚️ **Multiple Recording Modes** - Flexible control over when to record/replay
- 📦 **Multiple Interactions** - Store many request/response pairs in one
  cassette
- 🎭 **Templating** - Parameterized cassettes for dynamic values (IDs,
  timestamps, etc.)
- 🔀 **Cross-Process Support** - Explicit shared sessions for Task.async and
  GenServer

## Quick Start

```elixir
import ReqCassette

test "fetches user data" do
  with_cassette "github_user", fn plug ->
    response = Req.get!("https://api.github.com/users/wojtekmach", plug: plug)
    assert response.status == 200
    assert response.body["login"] == "wojtekmach"
  end
end
```

**First run**: Records to `test/cassettes/github_user.json` **Subsequent runs**:
Replays instantly from cassette (no network!)

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:req, "~> 0.5.15"},
    {:req_cassette, "~> 0.2.0"}
  ]
end
```

## Usage

### Basic Usage with `with_cassette`

```elixir
import ReqCassette

test "API integration" do
  with_cassette "my_api_call", fn plug ->
    response = Req.get!("https://api.example.com/data", plug: plug)
    assert response.status == 200
  end
end
```

### Recording Modes

#### Quick Reference

| Mode      | When to Use                      | Cassette Behavior                          |
| --------- | -------------------------------- | ------------------------------------------ |
| `:record` | **Default - use for most tests** | Records new interactions, replays existing |
| `:replay` | CI/CD, deterministic testing     | Only replays, errors if cassette missing   |
| `:bypass` | Debugging, temporary disable     | Ignores cassettes, always hits network     |

#### Examples

```elixir
# :record (default) - Record if cassette/interaction missing, otherwise replay
with_cassette "api_call", fn plug ->
  Req.get!("https://api.example.com/data", plug: plug)
end

# :replay - Only replay from cassette, error if missing (great for CI)
with_cassette "api_call", [mode: :replay], fn plug ->
  Req.get!("https://api.example.com/data", plug: plug)
end

# :bypass - Ignore cassettes entirely, always use network
with_cassette "api_call", [mode: :bypass], fn plug ->
  Req.get!("https://api.example.com/data", plug: plug)
end

# To re-record a cassette: delete it first, then run with :record
File.rm!("test/cassettes/api_call.json")
with_cassette "api_call", fn plug ->
  Req.get!("https://api.example.com/data", plug: plug)
end
```

#### Multiple Requests Per Cassette

The `:record` mode safely handles tests with multiple HTTP requests:

```elixir
# ✅ All interactions are saved
with_cassette "agent_conversation", fn plug ->
  response1 = Req.post!(url, json: %{msg: "Hello"}, plug: plug)
  response2 = Req.post!(url, json: %{msg: "How are you?"}, plug: plug)
  response3 = Req.post!(url, json: %{msg: "Goodbye"}, plug: plug)
end
# Result: All 3 interactions saved ✅
```

#### Best Practices

1. **Use `:record` by default** - Safe for all test types (single or
   multi-request)
2. **Use `:replay` in CI** - Ensures tests don't make unexpected API calls
3. **Delete cassettes to re-record** - Remove the cassette file to force a fresh
   recording

### Mismatch Diagnostics

When a request doesn't match any stored interaction, ReqCassette provides
detailed diagnostics to help you identify the problem:

```
** (RuntimeError) ReqCassette: No matching interaction found in cassette test/cassettes/api.json

Request: POST /api/users
Matching on: [:method, :uri, :query, :headers, :body]

This cassette exists but doesn't contain a matching interaction.
Either add the interaction to the cassette or use mode: :record.

🟢 :method match
🔴 :uri NO match
🟢 :query match
🟢 :headers match
🟢 :body match

🔬 :uri details

Record 1:
stored: "https://api.example.com/api/v1/users"
value:  "https://api.example.com/api/v2/users"
```

The diagnostics show:

- **Summary** - Which matchers matched (🟢) and which didn't (🔴)
- **Details** - For mismatched fields, the stored vs incoming values for each
  record

This makes it easy to identify why a cassette isn't matching - whether it's a
changed URL, different headers, modified request body, etc.

### Sensitive Data Filtering

**⚠️ Critical for LLM APIs:** Always filter authorization headers to prevent API
keys from being saved to cassettes.

```elixir
with_cassette "auth",
  [
    filter_request_headers: ["authorization", "x-api-key", "cookie"],
    filter_response_headers: ["set-cookie"],
    filter_sensitive_data: [
      {~r/api_key=[\w-]+/, "api_key=<REDACTED>"},
      {~r/"token":"[^"]+"/, ~s("token":"<REDACTED>")}
    ]
  ],
  fn plug ->
    Req.post!("https://api.example.com/login",
      json: %{username: "user", password: "secret"},
      plug: plug)
  end
```

**📖 See the
[Sensitive Data Filtering Guide](docs/SENSITIVE_DATA_FILTERING.md)** for
comprehensive documentation on protecting secrets, common patterns, and best
practices.

### Templating

**Parameterized cassettes** for testing APIs with dynamic values. One cassette
can handle multiple requests with different IDs, timestamps, or other varying
data.

#### Quick Example

```elixir
# One cassette handles ALL product SKUs!
test "product lookup with any SKU" do
  with_cassette "product_lookup",
    [
      template: [
        patterns: [sku: ~r/\d{4}-\d{4}/]
      ]
    ],
    fn plug ->
      # First call: Records
      response1 = Req.get!("https://api.example.com/products/1234-5678", plug: plug)
      assert response1.body["sku"] == "1234-5678"

      # Second call: Replays with DIFFERENT SKU!
      response2 = Req.get!("https://api.example.com/products/9999-8888", plug: plug)
      assert response2.body["sku"] == "9999-8888"  # ✅ Substituted!
      assert response2.body["name"] == "Widget"     # ✅ Same static data
    end
end
```

#### How It Works

1. **Extract** dynamic values using regex patterns (`1234-5678`)
2. **Template** request/response with markers (`{{sku.0}}`)
3. **Match** on structure, not values
4. **Substitute** new values during replay

#### Perfect For

- **E-commerce APIs** - Product SKUs, order IDs
- **User management** - User IDs, email addresses
- **LLM APIs** - Conversation IDs, timestamps, request IDs
- **Pagination** - Cursor tokens, page numbers
- **Time-sensitive APIs** - ISO timestamps, date ranges

#### Common Patterns

```elixir
template: [
  patterns: [
    # Product SKUs
    sku: ~r/\d{4}-\d{4}/,

    # Order IDs
    order_id: ~r/ORD-\d+/,

    # UUIDs
    uuid: ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,

    # Timestamps
    timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/,

    # Conversation IDs (LLM APIs)
    conversation_id: ~r/conv_[a-zA-Z0-9]+/
  ]
]
```

#### LLM Example

```elixir
test "LLM chat with varying conversation IDs" do
  with_cassette "llm_chat",
    [
      filter_request_headers: ["authorization"],  # Security first!
      template: [
        patterns: [
          conversation_id: ~r/conv_[a-zA-Z0-9]+/,
          message_id: ~r/msg_[a-zA-Z0-9]+/
        ]
      ]
    ],
    fn plug ->
      # Different conversation IDs - same cassette!
      {:ok, response} = ReqLLM.generate_text(
        "anthropic:claude-sonnet-4-20250514",
        "Explain recursion",
        conversation_id: "conv_xyz789",  # Works with any ID
        req_http_options: [plug: plug]
      )

      assert response.choices[0].message.content =~ "function calls itself"
    end
end
```

**📖 See the [Templating Guide](docs/guides/templating.md)** for comprehensive
documentation, advanced patterns, debugging tips, and best practices.

### Custom Request Matching

Control which requests match which cassette interactions:

```elixir
# Match only on method and URI (ignore headers, query params, body)
with_cassette "flexible",
  [match_requests_on: [:method, :uri]],
  fn plug ->
    Req.post!("https://api.example.com/data",
      json: %{timestamp: DateTime.utc_now()},
      plug: plug)
  end

# Match on method, URI, and query params (but not body)
with_cassette "search",
  [match_requests_on: [:method, :uri, :query]],
  fn plug ->
    Req.get!("https://api.example.com/search?q=elixir", plug: plug)
  end
```

### With Helper Functions

Perfect for passing plug to reusable functions:

```elixir
defmodule MyApp.API do
  def fetch_user(id, opts \\ []) do
    Req.get!("https://api.example.com/users/#{id}", plug: opts[:plug])
  end

  def create_user(data, opts \\ []) do
    Req.post!("https://api.example.com/users", json: data, plug: opts[:plug])
  end
end

test "user operations" do
  with_cassette "user_workflow", fn plug ->
    user = MyApp.API.fetch_user(1, plug: plug)
    assert user.body["id"] == 1

    new_user = MyApp.API.create_user(%{name: "Bob"}, plug: plug)
    assert new_user.status == 201
  end
end
```

## Usage with ReqLLM

Save money on LLM API calls during testing:

```elixir
import ReqCassette

test "LLM generation" do
  with_cassette "claude_recursion", fn plug ->
    {:ok, response} = ReqLLM.generate_text(
      "anthropic:claude-sonnet-4-20250514",
      "Explain recursion in one sentence",
      max_tokens: 100,
      req_http_options: [plug: plug]
    )

    assert response.choices[0].message.content =~ "function calls itself"
  end
end
```

**First run**: Costs money (real API call) **Subsequent runs**: FREE (replays
from cassette)

See [docs/REQ_LLM_INTEGRATION.md](docs/REQ_LLM_INTEGRATION.md) for detailed
ReqLLM integration guide.

## Cassette Format

Cassettes are stored as pretty-printed JSON with native JSON objects:

```json
{
  "version": "1.0",
  "interactions": [
    {
      "request": {
        "method": "GET",
        "uri": "https://api.example.com/users/1",
        "query_string": "",
        "headers": {
          "accept": ["application/json"]
        },
        "body_type": "text",
        "body": ""
      },
      "response": {
        "status": 200,
        "headers": {
          "content-type": ["application/json"]
        },
        "body_type": "json",
        "body_json": {
          "id": 1,
          "name": "Alice"
        }
      },
      "recorded_at": "2025-10-16T12:00:00Z"
    }
  ]
}
```

### Body Types

ReqCassette automatically detects and handles three body types:

- **`json`** - Stored as native JSON objects (pretty-printed, readable)
- **`text`** - Plain text (HTML, XML, CSV, etc.)
- **`blob`** - Binary data (images, PDFs) stored as base64

## Configuration Options

```elixir
with_cassette "example",
  [
    cassette_dir: "test/cassettes",              # Where to store cassettes
    mode: :record,                                # Recording mode
    match_requests_on: [:method, :uri, :body],   # Request matching criteria
    filter_sensitive_data: [                      # Regex-based redaction
      {~r/api_key=[\w-]+/, "api_key=<REDACTED>"}
    ],
    filter_request_headers: ["authorization"],   # Headers to remove from requests
    filter_response_headers: ["set-cookie"],     # Headers to remove from responses
    before_record: fn interaction ->              # Custom filtering callback
      # Modify interaction before saving
      interaction
    end
  ],
  fn plug ->
    # Your code here
  end
```

## Sequential Matching

By default, ReqCassette uses **first-match**: same request always returns same
response. This works well for most tests:

```elixir
with_cassette "api_test", fn plug ->
  Req.get!("/users/1", plug: plug)  # → Alice
  Req.get!("/users/2", plug: plug)  # → Bob
  Req.get!("/users/1", plug: plug)  # → Alice (same as first call)
end
```

For cases where identical requests should return **different responses**
(polling, state changes), enable sequential matching with `sequential: true`:

```elixir
# Polling API that returns different states over time
with_cassette "polling_test", [sequential: true], fn plug ->
  Req.get!("/job/status", plug: plug)  # → {"status": "pending"}
  Req.get!("/job/status", plug: plug)  # → {"status": "running"}
  Req.get!("/job/status", plug: plug)  # → {"status": "completed"}
end
```

**Templates automatically enable sequential matching** - no need to add
`sequential: true` when using `template: [...]`.

## Cross-Process Sequential Matching (Task.async, GenServer, etc.)

> **⚠️ Note:** Shared sessions are only needed for **sequential matching** with
> spawned processes. If you use the default first-match behavior, no special
> handling is needed.

When using sequential matching with spawned processes, the process dictionary
can't be shared. Use `start_shared_session/0`:

```elixir
# ✅ WITH shared session - all processes share sequential state
session = ReqCassette.start_shared_session()
try do
  with_cassette "parallel_requests", [session: session, sequential: true], fn plug ->
    tasks = for i <- 1..3 do
      Task.async(fn ->
        Req.post!("https://api.example.com", plug: plug, json: %{id: i})
      end)
    end
    results = Task.await_many(tasks)
    # Tasks correctly get interactions 0, 1, 2 (in order of execution)
  end
after
  ReqCassette.end_shared_session(session)
end
```

### When You Need Shared Sessions

You need a shared session when ALL of these apply:

- Using sequential matching (`sequential: true` or `template: [...]`)
- Making HTTP requests from spawned processes (Task.async, GenServer, etc.)

You do NOT need a shared session when:

- Using default first-match behavior (most common case)
- All requests are made from the same process

### Best Practice for Test Setup

For tests with cross-process sequential matching, use ExUnit's setup:

```elixir
defmodule MyApp.ParallelAPITest do
  use ExUnit.Case, async: true
  import ReqCassette

  setup do
    session = ReqCassette.start_shared_session()
    on_exit(fn -> ReqCassette.end_shared_session(session) end)
    %{session: session}
  end

  test "parallel API calls", %{session: session} do
    with_cassette "parallel_test", [session: session, sequential: true], fn plug ->
      tasks = for i <- 1..3 do
        Task.async(fn -> Req.get!("https://api.example.com/#{i}", plug: plug) end)
      end
      Task.await_many(tasks)
    end
  end
end
```

## Why ReqCassette over ExVCR?

| Feature                  | ReqCassette                  | ExVCR                    |
| ------------------------ | ---------------------------- | ------------------------ |
| Async-safe               | ✅ Yes                       | ❌ No                    |
| HTTP client              | Req only                     | hackney, finch, etc.     |
| Implementation           | Req.Test + Plug              | :meck (global)           |
| Pretty-printed cassettes | ✅ Yes (native JSON objects) | ❌ No (escaped strings)  |
| Multiple interactions    | ✅ Yes (one file per test)   | ❌ No (one file per req) |
| Sensitive data filtering | ✅ Built-in                  | ⚠️ Manual                |
| Recording modes          | ✅ 3 modes                   | ⚠️ Limited               |
| Maintenance              | Low                          | High                     |

## Development

### Quick Commands

```bash
# Development workflow
mix precommit  # Format, check, test (run before commit)
mix ci         # CI checks (read-only format check)
```

### Testing

```bash
# Run all tests (82 tests)
mix test

# Run specific test suite
mix test test/req_cassette/with_cassette_test.exs

# Run demos
mix run examples/httpbin_demo.exs
ANTHROPIC_API_KEY=sk-... mix run examples/req_llm_demo.exs
```

## Documentation

### Guides

- **[Templating Guide](docs/guides/templating.md)** - Parameterized cassettes
  for dynamic values
- **[Sensitive Data Filtering Guide](docs/SENSITIVE_DATA_FILTERING.md)** -
  Protect API keys and secrets
- **[ReqLLM Integration Guide](docs/REQ_LLM_INTEGRATION.md)** - Testing LLM
  applications
- **[Migration Guide v0.4 → v0.5](docs/MIGRATION_V0.4_TO_V0.5.md)** -
  Cross-process session support
- **[Migration Guide v0.1 → v0.2](docs/MIGRATION_V0.1_TO_V0.2.md)** - API
  changes from v0.1

### Reference

- [ROADMAP.md](ROADMAP.md) - Development roadmap and v0.2 features
- [DESIGN_SPEC.md](docs/DESIGN_SPEC.md) - Complete design specification
- [DEVELOPMENT.md](docs/DEVELOPMENT.md) - Development guide

## Example Test

```elixir
defmodule MyApp.APITest do
  use ExUnit.Case, async: true

  import ReqCassette

  @cassette_dir "test/fixtures/cassettes"

  test "fetches user data" do
    with_cassette "github_user", [cassette_dir: @cassette_dir], fn plug ->
      response = Req.get!("https://api.github.com/users/wojtekmach", plug: plug)

      assert response.status == 200
      assert response.body["login"] == "wojtekmach"
      assert response.body["public_repos"] > 0
    end
  end

  test "handles API errors gracefully" do
    with_cassette "not_found", [cassette_dir: @cassette_dir], fn plug ->
      response = Req.get!("https://api.github.com/users/nonexistent-user-xyz",
        plug: plug,
        retry: false
      )

      assert response.status == 404
    end
  end
end
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file
for details.

## Contributing

Contributions welcome! Please open an issue or PR.

See [ROADMAP.md](ROADMAP.md) for planned features and development priorities.
