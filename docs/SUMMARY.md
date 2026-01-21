# ReqCassette - Project Summary

## What is ReqCassette?

ReqCassette is a VCR-style record-and-replay library for Elixir's Req HTTP
client. It allows you to record HTTP responses to files ("cassettes") and replay
them in subsequent test runs, making your tests faster, deterministic, and free
from network dependencies.

## Key Features

- **Built on Req's native testing infrastructure** - Uses `Req.Test` and Plug,
  not global mocking
- **Async-safe** - Works with `async: true` in ExUnit
- **Simple API** - Use `with_cassette/3` macro for clean test setup
- **Multiple Recording Modes** - `:record`, `:replay`, or `:passthrough`
- **Multiple Interactions** - Store many request/response pairs in one cassette
- **Templating** - Parameterized cassettes for dynamic values (IDs, timestamps)
- **Cross-Process Support** - Shared sessions for `Task.async` and `GenServer`
- **ReqLLM Integration** - Perfect for testing LLM applications (save $$$ on API
  calls!)
- **JSON cassettes** - Human-readable, easy to inspect and edit

## Project Structure

```
req_cassette/
├── lib/
│   └── req_cassette/
│       ├── plug.ex           # Main ReqCassette.Plug implementation
│       ├── cassette.ex       # Cassette file handling
│       ├── session.ex        # Sequential matching & cross-process support
│       └── template/         # Templating system
├── test/
│   └── req_cassette/
│       ├── plug_test.exs     # Basic HTTP tests
│       ├── with_cassette_test.exs  # with_cassette macro tests
│       ├── cross_process_test.exs  # Cross-process session tests
│       └── template/         # Template feature tests
├── examples/
│   ├── httpbin_demo.exs      # Demo with httpbin.org
│   └── req_llm_demo.exs      # Demo with ReqLLM
└── docs/
    ├── guides/
    │   ├── templating.md     # Templating guide
    │   ├── llm-testing.md    # LLM testing guide
    │   └── filtering.md      # Sensitive data filtering
    └── SUMMARY.md            # This file
```

## Quick Start

### Installation

```elixir
# mix.exs
def deps do
  [
    {:req, "~> 0.5.15"},
    {:req_cassette, "~> 0.5.0"}
  ]
end
```

### Basic Usage

```elixir
import ReqCassette

# Record and replay HTTP interactions
with_cassette "get_user", fn plug ->
  response = Req.get!("https://api.example.com/users/1", plug: plug)
  assert response.body["name"] == "Alice"
end
```

### With Options

```elixir
with_cassette "create_user", [mode: :record, cassette_dir: "test/cassettes"], fn plug ->
  response = Req.post!(
    "https://api.example.com/users",
    plug: plug,
    json: %{name: "Bob"}
  )
  assert response.status == 201
end
```

### With Templating (for LLM APIs)

```elixir
with_cassette "llm_chat", [template: [preset: :anthropic]], fn plug ->
  response = Req.post!(
    "https://api.anthropic.com/v1/messages",
    plug: plug,
    json: %{model: "claude-sonnet-4-20250514", messages: [%{role: "user", content: "Hello"}]}
  )
  # Dynamic IDs are automatically templated for replay
end
```

### Cross-Process Support

```elixir
# For Task.async, GenServer, or any spawned process making HTTP requests
session = ReqCassette.start_shared_session()
try do
  with_cassette "parallel_test", [session: session], fn plug ->
    tasks = for i <- 1..3 do
      Task.async(fn ->
        Req.get!("https://api.example.com/item/#{i}", plug: plug)
      end)
    end
    Task.await_many(tasks)
  end
after
  ReqCassette.end_shared_session(session)
end
```

## Recording Modes

| Mode           | Behavior                                         |
| -------------- | ------------------------------------------------ |
| `:record`      | Record new interactions, replay existing matches |
| `:replay`      | Only replay from cassette, error if no match     |
| `:passthrough` | Bypass cassette, always hit network              |

## Cassette Format (v1.0)

```json
{
  "version": "1.0",
  "interactions": [
    {
      "request": {
        "method": "GET",
        "uri": "https://api.example.com/users/1",
        "headers": { "accept": ["application/json"] },
        "body": ""
      },
      "response": {
        "status": 200,
        "headers": { "content-type": ["application/json"] },
        "body": "{\"id\":1,\"name\":\"Alice\"}"
      }
    }
  ]
}
```

## Testing

```bash
# Run all tests
mix test

# Run specific test suites
mix test test/req_cassette/with_cassette_test.exs
mix test test/req_cassette/cross_process_test.exs

# Run LLM tests (requires API key)
ANTHROPIC_API_KEY=sk-... mix test --include req_llm
```

## Comparison with ExVCR

| Feature                     | ReqCassette           | ExVCR                         |
| --------------------------- | --------------------- | ----------------------------- |
| Async-safe                  | Yes                   | No (requires `async: false`)  |
| HTTP client                 | Req only              | hackney, finch, ibrowse, etc. |
| Implementation              | Req.Test + Plug       | :meck (global patching)       |
| Multi-interaction cassettes | Yes                   | Yes                           |
| Templating                  | Yes (built-in)        | No                            |
| Cross-process support       | Yes (shared sessions) | No                            |

## Documentation

- **[README](../README.md)** - Full documentation and examples
- **[Templating Guide](guides/templating.md)** - Parameterized cassettes
- **[LLM Testing Guide](guides/llm-testing.md)** - Testing LLM applications
- **[Filtering Guide](guides/filtering.md)** - Protecting sensitive data

## References

- [Req Library](https://hexdocs.pm/req)
- [Req.Test Documentation](https://hexdocs.pm/req/Req.Test.html)
- [HexDocs](https://hexdocs.pm/req_cassette)
