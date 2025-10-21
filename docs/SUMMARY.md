# ReqCassette - Project Summary

## What is ReqCassette?

ReqCassette is a VCR-style record-and-replay library for Elixir's Req HTTP
client. It allows you to record HTTP responses to files ("cassettes") and replay
them in subsequent test runs, making your tests faster, deterministic, and free
from network dependencies.

## Key Features

- ✅ **Built on Req's native testing infrastructure** - Uses `Req.Test` and
  Plug, not global mocking
- ✅ **Async-safe** - Works with `async: true` in ExUnit
- ✅ **Simple API** - Just add `plug: {ReqCassette.Plug, opts}` to your Req
  calls
- ✅ **ReqLLM Integration** - Perfect for testing LLM applications (save $$$ on
  API calls!)
- ✅ **JSON cassettes** - Human-readable, easy to inspect and edit
- ✅ **Automatic body decoding** - Properly handles JSON responses

## Project Structure

```
req_cassette/
├── lib/
│   └── req_cassette/
│       └── plug.ex              # Main ReqCassette.Plug implementation
├── test/
│   └── req_cassette/
│       ├── plug_test.exs        # Basic HTTP tests (using Bypass)
│       └── req_llm_test.exs     # ReqLLM integration tests
├── examples/
│   ├── httpbin_demo.exs         # Demo with httpbin.org
│   ├── req_llm_demo.exs         # Demo with ReqLLM
│   └── simple_demo.exs          # Basic demo (requires Bypass)
├── livebooks/
│   └── req_llm.livemd           # Interactive demo
└── docs/
    ├── guides/
    │   ├── req-llm-integration.md   # ReqLLM usage guide
    │   ├── filtering.md             # Filtering sensitive data guide
    │   └── templating.md            # Templating guide
    └── SUMMARY.md               # This file
```

## Quick Start

### Installation

```elixir
# mix.exs
def deps do
  [
    {:req, "~> 0.5.15"},
    {:req_cassette, path: "."} # or from hex when published
  ]
end
```

### Basic Usage

```elixir
# First call - records to cassette
response = Req.get!(
  "https://api.example.com/users/1",
  plug: {ReqCassette.Plug, %{cassette_name: "get_user", cassette_dir: "test/cassettes", mode: :record}}
)

# Second call - replays from cassette (instant, no network!)
response = Req.get!(
  "https://api.example.com/users/1",
  plug: {ReqCassette.Plug, %{cassette_name: "get_user", cassette_dir: "test/cassettes", mode: :record}}
)
```

### With ReqLLM

```elixir
{:ok, response} = ReqLLM.generate_text(
  "anthropic:claude-sonnet-4-20250514",
  "Explain recursion",
  max_tokens: 100,
  req_http_options: [
    plug: {ReqCassette.Plug, %{cassette_name: "explain_recursion", cassette_dir: "test/cassettes", mode: :record}}
  ]
)
# First call costs money, subsequent calls are free!
```

## Implementation Details

### Architecture

ReqCassette uses Req's built-in `:plug` option to intercept HTTP requests:

1. When a Req request is made with `plug: {ReqCassette.Plug, ...}`:

   - The plug receives a `%Plug.Conn{}` representing the outgoing request
   - It checks if a matching cassette exists
   - If yes: loads and returns the saved response
   - If no: forwards the request, saves the response, returns it

2. The cassette is a JSON file containing:

   - HTTP status code
   - Response headers (including `content-type`)
   - Response body (as a string)

3. When replaying:
   - The body is returned as a string
   - Req's `decode_body` step sees the `content-type` header
   - Req automatically decodes JSON (just like a real response!)

### Key Fixes

The original prototype had several bugs that were fixed:

1. **Missing request body** - POST/PUT bodies weren't being forwarded

   - Fixed by calling `Plug.Conn.read_body/1`

2. **Response bodies not decoded** - Bodies were strings instead of maps

   - Root cause: Missing `content-type` header in cassettes
   - Fixed by ensuring headers are properly saved/restored

3. **Poor scheme detection** - Only looked at port number
   - Fixed by using `conn.scheme` when available

## Testing

### Run All Tests

```bash
mix test
```

### Run Specific Test Suites

```bash
# Basic HTTP tests
mix test test/req_cassette/plug_test.exs

# ReqLLM integration tests
mix test test/req_cassette/req_llm_test.exs

# Run skipped test with real API (requires ANTHROPIC_API_KEY)
ANTHROPIC_API_KEY=sk-... mix test --include req_llm
```

### Run Demos

```bash
# HTTP demo (uses httpbin.org)
mix run examples/httpbin_demo.exs

# ReqLLM demo (requires ANTHROPIC_API_KEY)
ANTHROPIC_API_KEY=sk-... mix run examples/req_llm_demo.exs
```

## Test Coverage

- ✅ GET requests
- ✅ POST requests with JSON body
- ✅ Replay from cassette
- ✅ Verify no network call during replay
- ✅ ReqLLM integration with mocked server
- ✅ Content-type header preservation
- ✅ JSON body decoding

## Cassette Format

Example cassette file (`test/cassettes/abc123.json`):

```json
{
  "status": 200,
  "headers": {
    "content-type": ["application/json"],
    "cache-control": ["max-age=0, private, must-revalidate"]
  },
  "body": "{\"id\":1,\"name\":\"Alice\"}"
}
```

### Cassette Matching

Cassettes are matched by hashing:

- HTTP method
- Request path
- Query string
- **Request body**

This creates a unique filename (e.g., `f05468d0c975ed8053216ec300d25c9d.json`).

## Design Decisions

### Why Req.Test + Plug instead of :meck?

ExVCR uses `:meck` to globally patch HTTP client modules. This approach:

- ❌ Breaks `async: true` (global state)
- ❌ Requires adapters for each HTTP client
- ❌ Tightly coupled to client internals

ReqCassette uses Req's native plug system:

- ✅ Process-isolated (async-safe)
- ✅ Works with any Req adapter
- ✅ Uses stable, public APIs
- ✅ Aligns with modern Elixir testing practices

### Why JSON for cassettes?

- Human-readable
- Easy to inspect and debug
- Can be manually edited if needed
- Works well with version control
- Fast to parse (using Jason)

### Why store body as string?

The cassette stores the response body as a string (not pre-decoded) because:

1. It preserves the original wire format
2. Req's `decode_body` step can process it normally
3. Content-type header tells Req how to decode it
4. Ensures replay behaves identically to real responses

## Future Enhancements

Potential features (not yet implemented):

- [ ] Custom cassette naming
- [ ] Request body matching
- [ ] Header-based matching
- [ ] Cassette expiration
- [ ] Pretty-printed JSON cassettes
- [ ] YAML serializer
- [ ] Streaming support
- [ ] use_cassette/2 macro (like ExVCR)

## Comparison with ExVCR

| Feature        | ReqCassette          | ExVCR                           |
| -------------- | -------------------- | ------------------------------- |
| Async-safe     | ✅ Yes               | ❌ No (requires `async: false`) |
| HTTP client    | Req only             | hackney, finch, ibrowse, etc.   |
| Implementation | Req.Test + Plug      | :meck (global patching)         |
| Setup          | Simple (plug option) | Medium (config + adapter)       |
| Maintenance    | Low (stable APIs)    | High (adapter per client)       |

## License

[Add your license here]

## Contributing

Contributions welcome! Please open an issue or PR.

## References

- [Req Library](https://hexdocs.pm/req)
- [Req.Test Documentation](https://hexdocs.pm/req/Req.Test.html)
- [Plug Specification](https://hexdocs.pm/plug)
- [ExVCR](https://hexdocs.pm/exvcr)
- [Ruby VCR](https://github.com/vcr/vcr)
- [ReqLLM](https://hexdocs.pm/req_llm)

## Credits

- Inspired by Ruby's VCR and Elixir's ExVCR
- Built on top of the excellent Req library by Wojtek Mach
- ReqLLM integration enabled by the ReqLLM library
