# Migration Guide: v0.1 → v0.2

This guide helps you upgrade from ReqCassette v0.1 to v0.2, which introduces
significant improvements along with some breaking changes.

## Overview

v0.2.0 is a major release that adds:

- ✨ New `with_cassette/3` function API
- 📦 Multiple interactions per cassette file
- 🎨 Pretty-printed JSON with native JSON objects
- 🎚️ Four recording modes (replay, record, record_missing, bypass)
- 🎯 Configurable request matching
- 🔒 Comprehensive sensitive data filtering
- 📝 Human-readable cassette filenames

**Migration time:** ~15-30 minutes for most projects

## Breaking Changes

### 1. API Change: Direct Plug Usage → `with_cassette/3`

**v0.1.0 (Old):**

```elixir
response = Req.get!(
  "https://api.example.com/users/1",
  plug: {ReqCassette.Plug, %{cassette_dir: "test/cassettes"}}
)
```

**v0.2.0 (New):**

```elixir
with_cassette "user_api", [cassette_dir: "test/cassettes"], fn plug ->
  Req.get!("https://api.example.com/users/1", plug: plug)
end
```

**Why:** The new API provides:

- Human-readable cassette names
- Better support for multiple interactions
- Cleaner test code
- Explicit plug passing for helper functions

> #### Cassette Naming Best Practice {: .warning}
>
> **Always provide a cassette name** as the first argument to `with_cassette/3`.
> This creates human-readable cassette files that are easy to identify, manage,
> and understand.
>
> **✅ Good** - Human-readable cassette:
>
> ```elixir
> with_cassette "github_user_profile", [cassette_dir: "test/cassettes"], fn plug ->
>   Req.get!("https://api.github.com/users/wojtekmach", plug: plug)
> end
> # Creates: test/cassettes/github_user_profile.json
> ```
>
> **❌ Avoid** - Direct plug usage without cassette name (v0.1 style):
>
> ```elixir
> Req.get!("https://api.example.com/users/1",
>   plug: {ReqCassette.Plug, %{cassette_dir: "test/cassettes"}})
> # Creates: test/cassettes/a1b2c3d4e5f6.json (cryptic MD5 hash)
> ```
>
> While direct plug usage still works for backward compatibility, it generates
> MD5-hashed filenames that are difficult to identify and maintain.

### 2. Cassette Format: Simple → v1.0 with Interactions

**v0.1.0 Format:**

```json
{
  "status": 200,
  "headers": {
    "content-type": ["application/json"]
  },
  "body": "{\"id\":1,\"name\":\"Alice\"}"
}
```

**v0.2.0 Format:**

```json
{
  "version": "1.0",
  "interactions": [
    {
      "request": {
        "method": "GET",
        "uri": "https://api.example.com/users/1",
        "query_string": "",
        "headers": { "accept": ["application/json"] },
        "body_type": "text",
        "body": ""
      },
      "response": {
        "status": 200,
        "headers": { "content-type": ["application/json"] },
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

**What changed:**

- Cassettes now contain multiple interactions
- JSON responses stored as native objects (not escaped strings)
- Full request metadata captured
- Body type discrimination (json, text, blob)
- Timestamps for each interaction

**Good news:** v0.1 cassettes are automatically migrated on first load!

### 3. Cassette Filenames: MD5 Hashes → Human-Readable

**v0.1.0:**

```
test/cassettes/
  ├── a1b2c3d4e5f6.json  # ❓ What is this?
  ├── f7e8d9c0b1a2.json  # ❓ And this?
  └── 9876543210ab.json  # ❓ No idea!
```

**v0.2.0:**

```
test/cassettes/
  ├── github_user.json       # ✅ Clear!
  ├── stripe_payment.json    # ✅ Obvious!
  └── anthropic_chat.json    # ✅ Self-documenting!
```

**Action required:** You'll need to re-record cassettes with new names.

### 4. Default Recording Mode: Implicit → Explicit

**v0.1.0:**

- Only one implicit mode (always record if cassette missing)
- No control over replay-only or force-record behavior

**v0.2.0:**

- Four explicit modes: `:record_missing` (default), `:replay`, `:record`,
  `:bypass`
- Better control for CI/development workflows
- Default `mode: :record_missing` behaves like v0.1

**No action required** if you want v0.1 behavior (record-if-missing).

### 5. ⚠️ Critical: `:record` Mode Behavior with Multi-Request Tests

The `:record` mode overwrites the cassette file on **each HTTP request**, not
once at the end of the test. For tests making multiple sequential requests
(e.g., LLM agents, multi-turn conversations, API workflows), **only the last
request will be saved** to the cassette.

**Example of Silent Failure:**

```elixir
# ❌ BROKEN - Only saves the last interaction!
with_cassette "agent_workflow", [mode: :record], fn plug ->
  {:ok, agent} = MyAgent.start_link(plug: plug)
  Agent.prompt(agent, "Turn 1")  # Writes cassette with 1 interaction
  Agent.prompt(agent, "Turn 2")  # OVERWRITES cassette with 1 interaction
  Agent.prompt(agent, "Turn 3")  # OVERWRITES cassette with 1 interaction
end
# Result: Cassette only contains Turn 3 ❌
# Switching to mode: :replay will fail with "No matching interaction found"
```

**The Solution:**

Use `:record_missing` mode instead:

```elixir
# ✅ CORRECT - Accumulates all interactions
mode = if System.get_env("RECORD_CASSETTES"), do: :record_missing, else: :replay

with_cassette "agent_workflow", [mode: mode], fn plug ->
  {:ok, agent} = MyAgent.start_link(plug: plug)
  Agent.prompt(agent, "Turn 1")  # Cassette: [interaction 1]
  Agent.prompt(agent, "Turn 2")  # Cassette: [interaction 1, 2]
  Agent.prompt(agent, "Turn 3")  # Cassette: [interaction 1, 2, 3]
end
# Result: All 3 interactions saved ✅
```

**When to Use Each Mode:**

| Mode              | Use Case                              | Multi-Request Safe?                   |
| ----------------- | ------------------------------------- | ------------------------------------- |
| `:record_missing` | **Default for all tests**             | ✅ Yes - accumulates all interactions |
| `:record`         | Force re-record (single-request only) | ❌ No - overwrites on each request    |
| `:replay`         | CI/CD, deterministic testing          | ✅ Yes - read-only                    |
| `:bypass`         | Debugging, temporary disable          | N/A - no cassettes                    |

## Step-by-Step Migration

### Step 1: Update Dependency

Update `mix.exs`:

```elixir
def deps do
  [
    {:req, "~> 0.5.15"},
    {:req_cassette, "~> 0.2.0"}  # was: "~> 0.1.0"
  ]
end
```

Run:

```bash
mix deps.update req_cassette
```

### Step 2: Update Test Code

#### Simple GET Request

**Before (v0.1):**

```elixir
test "fetches user" do
  response = Req.get!(
    "https://api.example.com/users/1",
    plug: {ReqCassette.Plug, %{cassette_dir: "test/cassettes"}}
  )

  assert response.status == 200
  assert response.body["name"] == "Alice"
end
```

**After (v0.2):**

```elixir
import ReqCassette  # Add this to your test module

test "fetches user" do
  with_cassette "user_fetch", [cassette_dir: "test/cassettes"], fn plug ->
    response = Req.get!("https://api.example.com/users/1", plug: plug)

    assert response.status == 200
    assert response.body["name"] == "Alice"
  end
end
```

#### POST with JSON Body

**Before (v0.1):**

```elixir
test "creates user" do
  response = Req.post!(
    "https://api.example.com/users",
    json: %{name: "Bob"},
    plug: {ReqCassette.Plug, %{cassette_dir: "test/cassettes"}}
  )

  assert response.status == 201
end
```

**After (v0.2):**

```elixir
test "creates user" do
  with_cassette "user_create", [cassette_dir: "test/cassettes"], fn plug ->
    response = Req.post!(
      "https://api.example.com/users",
      json: %{name: "Bob"},
      plug: plug
    )

    assert response.status == 201
  end
end
```

#### With Helper Functions

**Before (v0.1):**

```elixir
defmodule MyApp.API do
  def fetch_user(id, opts \\ []) do
    Req.get!("https://api.example.com/users/#{id}", opts)
  end
end

test "API helper" do
  plug_opts = [plug: {ReqCassette.Plug, %{cassette_dir: "test/cassettes"}}]
  user = MyApp.API.fetch_user(1, plug_opts)
  assert user.body["id"] == 1
end
```

**After (v0.2):**

```elixir
defmodule MyApp.API do
  def fetch_user(id, opts \\ []) do
    Req.get!("https://api.example.com/users/#{id}", plug: opts[:plug])
  end
end

test "API helper" do
  with_cassette "api_helper", [cassette_dir: "test/cassettes"], fn plug ->
    user = MyApp.API.fetch_user(1, plug: plug)
    assert user.body["id"] == 1
  end
end
```

#### ReqLLM Integration

**Before (v0.1):**

```elixir
test "LLM call" do
  {:ok, response} = ReqLLM.generate_text(
    "anthropic:claude-sonnet-4",
    "Hello!",
    req_http_options: [
      plug: {ReqCassette.Plug, %{cassette_dir: "test/cassettes"}}
    ]
  )

  assert response.status == :ok
end
```

**After (v0.2):**

```elixir
test "LLM call" do
  with_cassette "claude_hello", [cassette_dir: "test/cassettes"], fn plug ->
    {:ok, response} = ReqLLM.generate_text(
      "anthropic:claude-sonnet-4",
      "Hello!",
      req_http_options: [plug: plug]
    )

    assert response.status == :ok
  end
end
```

### Step 3: Delete Old Cassettes (Optional but Recommended)

Since cassette format and naming changed, it's cleanest to start fresh:

```bash
# Backup old cassettes (optional)
cp -r test/cassettes test/cassettes.v0.1.backup

# Delete old cassettes
rm -rf test/cassettes/*.json

# Or just delete the entire directory
rm -rf test/cassettes
```

**Note:** v0.2 will auto-migrate v0.1 cassettes on first load, but with
placeholders for request details.

### Step 4: Re-run Tests to Re-record

```bash
mix test
```

This will:

1. Create new v1.0 format cassettes
2. Use human-readable filenames
3. Store JSON responses as native objects (much more readable!)

### Step 5: Verify Cassettes

Check that new cassettes are pretty-printed and human-readable:

```bash
cat test/cassettes/user_fetch.json
```

You should see:

```json
{
  "version": "1.0",
  "interactions": [
    {
      "request": { ... },
      "response": {
        "body_json": {
          "id": 1,
          "name": "Alice"
        }
      }
    }
  ]
}
```

Not the old escaped format:

```json
{
  "body": "{\"id\":1,\"name\":\"Alice\"}"
}
```

## New Features You Can Use

### 1. Recording Modes

Control when cassettes are created/used:

```elixir
# CI: Only use existing cassettes, error if missing
with_cassette "api_call", [mode: :replay], fn plug ->
  Req.get!("https://api.example.com/data", plug: plug)
end

# Force re-record (refresh stale cassettes)
with_cassette "api_call", [mode: :record], fn plug ->
  Req.get!("https://api.example.com/data", plug: plug)
end

# Disable cassettes temporarily for debugging
with_cassette "api_call", [mode: :bypass], fn plug ->
  Req.get!("https://api.example.com/data", plug: plug)
end
```

### 2. Custom Request Matching

Match requests flexibly (useful for APIs with timestamps or tokens):

```elixir
# Ignore query parameter differences
with_cassette "search",
  [match_requests_on: [:method, :uri]],
  fn plug ->
    # ?q=foo and ?q=bar both match the same cassette
    Req.get!("https://api.example.com/search?q=foo", plug: plug)
  end

# Ignore request body differences (useful for timestamps)
with_cassette "create",
  [match_requests_on: [:method, :uri, :query]],
  fn plug ->
    # Different timestamps in body still match
    Req.post!(url, json: %{data: "x", ts: now()}, plug: plug)
  end
```

### 3. Sensitive Data Filtering

**⚠️ Critical for LLM APIs:** Always filter authorization headers to prevent API
keys from being committed.

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
    Req.get!("https://api.example.com/data?api_key=secret", plug: plug)
  end
```

**📖 See the [Filtering Sensitive Data Guide](guides/filtering.md)** for
comprehensive documentation on protecting secrets, common patterns, and best
practices.

### 4. Multiple Interactions Per Cassette

Group related requests in one cassette:

```elixir
with_cassette "user_workflow", fn plug ->
  # All three requests stored in user_workflow.json
  user = Req.get!("https://api.example.com/users/1", plug: plug)
  posts = Req.get!("https://api.example.com/posts", plug: plug)
  comments = Req.get!("https://api.example.com/comments", plug: plug)

  {user, posts, comments}
end
```

## Troubleshooting

### Old cassettes not loading

**Symptom:** Tests fail with "Cassette not found" even though files exist.

**Cause:** Filename changed from MD5 hash to human-readable name.

**Fix:** Re-record cassettes or rename files manually (not recommended).

### Cassette only has 1 interaction but test makes multiple requests

**Symptom:** Tests pass when recording but fail with "No matching interaction
found" when replaying, even though cassette exists.

**Cause:** Used `:record` mode which overwrites the cassette on each request,
keeping only the last one.

**Fix:** Switch to `:record_missing` mode:

```elixir
# Change from:
with_cassette "test", [mode: :record], fn plug ->
  # ...
end

# To:
with_cassette "test", [mode: :record_missing], fn plug ->
  # ...
end
```

Then delete cassettes and re-record: `rm -rf test/cassettes/*.json && mix test`

### Tests fail with "No matching interaction found"

**Symptom:** Cassette exists but request doesn't match.

**Cause:** Request matching is now more strict by default (includes headers,
body).

**Fix:** Use custom `match_requests_on` to match more loosely:

```elixir
with_cassette "api_call",
  [match_requests_on: [:method, :uri]],  # Ignore query, headers, body
  fn plug ->
    # ...
  end
```

### Cassettes keep getting modified in git

**Symptom:** Cassette files show changes on every test run.

**Cause:** Likely timestamps or dynamic data in responses.

**Fix:** Use filtering to normalize dynamic data:

```elixir
with_cassette "api",
  [
    filter_sensitive_data: [
      # Normalize timestamps
      {~r/"timestamp":"[^"]+"/, ~s("timestamp":"<NORMALIZED>")},
      # Normalize UUIDs
      {~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, "UUID"}
    ]
  ],
  fn plug ->
    # ...
  end
```

### Want old v0.1 behavior exactly

If you want minimal changes:

```elixir
# This is almost identical to v0.1 behavior
with_cassette "my_cassette", [], fn plug ->
  Req.get!("https://api.example.com/data", plug: plug)
end
```

The only difference is you now have:

- Human-readable cassette names (better!)
- Pretty-printed JSON (better!)
- Automatic format migration (transparent)

## Common Migration Patterns

### Pattern 1: Module-Level Cassette Config

**Before (v0.1):**

```elixir
defmodule MyApp.APITest do
  use ExUnit.Case, async: true

  @cassette_opts %{cassette_dir: "test/cassettes"}

  test "test 1" do
    Req.get!("...", plug: {ReqCassette.Plug, @cassette_opts})
  end

  test "test 2" do
    Req.get!("...", plug: {ReqCassette.Plug, @cassette_opts})
  end
end
```

**After (v0.2):**

```elixir
defmodule MyApp.APITest do
  use ExUnit.Case, async: true

  import ReqCassette

  @cassette_dir "test/cassettes"

  test "test 1" do
    with_cassette "test_1", [cassette_dir: @cassette_dir], fn plug ->
      Req.get!("...", plug: plug)
    end
  end

  test "test 2" do
    with_cassette "test_2", [cassette_dir: @cassette_dir], fn plug ->
      Req.get!("...", plug: plug)
    end
  end
end
```

### Pattern 2: Shared Cassette for Multiple Tests

**Before (v0.1):**

```elixir
# All requests hashed to same cassette (confusing)
test "test 1" do
  Req.get!("...", plug: {ReqCassette.Plug, %{...}})
end

test "test 2" do
  Req.get!("...", plug: {ReqCassette.Plug, %{...}})
end
```

**After (v0.2):**

```elixir
# Explicit shared cassette
setup_all do
  with_cassette "shared_setup", fn plug ->
    # Record all setup requests
    data1 = Req.get!("...", plug: plug)
    data2 = Req.get!("...", plug: plug)
    {:ok, data1: data1, data2: data2}
  end
end

test "test 1", %{data1: data1} do
  # Use data1
end

test "test 2", %{data2: data2} do
  # Use data2
end
```

## Getting Help

If you run into issues:

1. Check the
   [CHANGELOG](https://github.com/lostbean/req_cassette/blob/main/CHANGELOG.md)
   for recent changes
2. Review
   [examples](https://github.com/lostbean/req_cassette/tree/main/examples) for
   working code
3. Open an issue on [GitHub](https://github.com/lostbean/req_cassette/issues)

## Summary

**What's better in v0.2:**

- ✅ Cleaner API with `with_cassette/3`
- ✅ Human-readable cassette names
- ✅ Pretty-printed JSON (40% smaller, dramatically more readable)
- ✅ Multiple recording modes
- ✅ Sensitive data filtering
- ✅ Custom request matching
- ✅ Multiple interactions per cassette

The effort is worth it - v0.2 is significantly better for production use!
