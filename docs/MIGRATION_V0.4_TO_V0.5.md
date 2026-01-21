# Migration Guide: v0.4 → v0.5

This guide helps you upgrade from ReqCassette v0.4 to v0.5.

## Overview

v0.5.0 adds **sequential matching** and **cross-process session support**.
Sequential matching is opt-in (or automatically enabled with templates).

## What's New

### Matching Behavior (Unchanged Default)

**First-Match (Default)** - Requests match the first interaction that matches
the request criteria. Same request always returns same response. This is the
same behavior as v0.4.

```elixir
with_cassette "api_test", fn plug ->
  Req.get!("/users/1", plug: plug)  # → Alice
  Req.get!("/users/2", plug: plug)  # → Bob
  Req.get!("/users/1", plug: plug)  # → Alice (same as first call)
end
```

### Sequential Matching (New, Opt-in)

When you need identical requests to return different responses, enable
sequential matching with `sequential: true`:

```elixir
# Polling API that returns different states over time
with_cassette "polling_test", [sequential: true], fn plug ->
  Req.get!("/job/status", plug: plug)  # → {"status": "pending"}
  Req.get!("/job/status", plug: plug)  # → {"status": "running"}
  Req.get!("/job/status", plug: plug)  # → {"status": "completed"}
end
```

Sequential matching is essential for:

- Identical requests expecting different responses (polling, state changes)
- Templated cassettes where multiple requests have the same structure
- Nested `with_cassette` calls using the same cassette name

**Templates automatically enable sequential matching** - no need to add
`sequential: true` when using `template: [...]`.

### Cross-Process Sessions

If your tests make HTTP requests from spawned processes and need sequential
matching, use shared sessions.

#### The Problem

```elixir
# Spawned processes don't share process dictionary state
with_cassette "parallel_test", [sequential: true], fn plug ->
  tasks = for i <- 1..3 do
    Task.async(fn ->
      Req.post!("https://api.example.com", plug: plug, json: %{id: i})
    end)
  end
  Task.await_many(tasks)
  # Each task incorrectly starts from interaction 0!
end
```

#### The Solution

```elixir
# Use shared sessions for cross-process sequential matching
session = ReqCassette.start_shared_session()
try do
  with_cassette "parallel_test", [session: session, sequential: true], fn plug ->
    tasks = for i <- 1..3 do
      Task.async(fn ->
        Req.post!("https://api.example.com", plug: plug, json: %{id: i})
      end)
    end
    Task.await_many(tasks)
    # Tasks correctly get interactions 0, 1, 2
  end
after
  ReqCassette.end_shared_session(session)
end
```

## New API

### New Option: `:sequential`

Enable sequential matching for a cassette:

```elixir
with_cassette "test", [sequential: true], fn plug ->
  # Requests match interactions in order
end
```

### `ReqCassette.start_shared_session/0`

Creates a shared session for cross-process cassette matching. Returns a session
reference to pass to `with_cassette/3`.

```elixir
session = ReqCassette.start_shared_session()
```

### `ReqCassette.end_shared_session/1`

Ends a shared session and cleans up resources. Always call this in an `after`
block.

```elixir
ReqCassette.end_shared_session(session)
```

### New Option: `:session`

Pass a shared session to `with_cassette/3`:

```elixir
with_cassette "test", [session: session, sequential: true], fn plug ->
  # All requests share session state across processes
end
```

## Migration Steps

### Step 1: Most Tests Need No Changes

If your tests use first-match behavior (different requests, or same request
expecting same response), no changes are needed.

### Step 2: Add `sequential: true` Where Needed

If you have tests where the same request should return different responses:

```elixir
# Before: might have worked by accident with recording order
with_cassette "polling_test", fn plug ->
  Req.get!("/status", plug: plug)  # interaction 0
  Req.get!("/status", plug: plug)  # interaction 1
  Req.get!("/status", plug: plug)  # interaction 2
end

# After: explicitly enable sequential matching
with_cassette "polling_test", [sequential: true], fn plug ->
  Req.get!("/status", plug: plug)  # interaction 0
  Req.get!("/status", plug: plug)  # interaction 1
  Req.get!("/status", plug: plug)  # interaction 2
end
```

### Step 3: Add Shared Sessions for Cross-Process Sequential Tests

If you have tests with spawned processes AND need sequential matching:

**Before:**

```elixir
test "parallel API calls" do
  with_cassette "parallel_test", fn plug ->
    tasks = Enum.map(1..3, fn i ->
      Task.async(fn -> make_request(plug, i) end)
    end)
    Task.await_many(tasks)
  end
end
```

**After (if sequential matching needed):**

```elixir
test "parallel API calls" do
  session = ReqCassette.start_shared_session()
  try do
    with_cassette "parallel_test", [session: session, sequential: true], fn plug ->
      tasks = Enum.map(1..3, fn i ->
        Task.async(fn -> make_request(plug, i) end)
      end)
      Task.await_many(tasks)
    end
  after
    ReqCassette.end_shared_session(session)
  end
end
```

### Step 4: Use ExUnit Setup (Recommended for Multiple Tests)

For cleaner tests, use ExUnit's setup:

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
      tasks = Enum.map(1..3, fn i ->
        Task.async(fn -> make_request(plug, i) end)
      end)
      Task.await_many(tasks)
    end
  end
end
```

## When to Use Each Feature

| Scenario                                | Options Needed                              |
| --------------------------------------- | ------------------------------------------- |
| Different requests, different responses | None (default)                              |
| Same request, same expected response    | None (default)                              |
| Retry logic                             | None (default)                              |
| Same request, different responses       | `sequential: true`                          |
| Templated requests                      | `template: [...]` (sequential auto-enabled) |
| Cross-process + sequential              | `session: session, sequential: true`        |

## Backward Compatibility

### `with_cassette` Usage

Fully backward compatible. Default behavior (first-match) is unchanged.

### Direct Plug Usage

If you use `ReqCassette.Plug` directly (without `with_cassette`), behavior is
unchanged - it uses first-match scanning.

```elixir
# Direct plug usage - unchanged behavior
Req.get!("https://api.example.com",
  plug: {ReqCassette.Plug, %{cassette_name: "test", cassette_dir: "cassettes"}}
)
```

## Troubleshooting

### "No matching interaction found" errors

If you see this error after upgrading:

1. **Check if you need sequential matching**: If you're replaying identical
   requests that should return different responses, add `sequential: true`.

2. **Request order changed**: With sequential matching, requests must be in the
   same order they were recorded. Re-record the cassette if order changed.

3. **Missing shared session**: If using `Task.async` or similar with sequential
   matching, add a shared session.

### Tests pass individually but fail together

This usually indicates cross-process race conditions. Add shared sessions to
affected tests.

## Summary

| Change                     | Action Required                     |
| -------------------------- | ----------------------------------- |
| Default (first-match)      | None                                |
| Sequential matching        | Add `sequential: true` where needed |
| Templates                  | None (sequential auto-enabled)      |
| Cross-process + sequential | Add shared session                  |
| Direct Plug usage          | None                                |
