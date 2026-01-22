defmodule ReqCassette do
  @moduledoc """
  A VCR-style record-and-replay library for Elixir's [Req](https://hexdocs.pm/req) HTTP client.

  ReqCassette captures HTTP responses to files ("cassettes") and replays them in subsequent
  test runs, making your tests faster, deterministic, and free from network dependencies.

  ## Features

  - 🎬 **Record & Replay** - Capture real HTTP responses and replay them instantly
  - ⚡ **Async-Safe** - Works with `async: true` in ExUnit
  - 🔌 **Built on Req.Test** - Uses Req's native testing infrastructure (no global mocking)
  - 🤖 **ReqLLM Integration** - Perfect for testing LLM applications
  - 📝 **Human-Readable** - Pretty-printed JSON cassettes with native JSON objects
  - 🎯 **Simple API** - Use `with_cassette/3` for clean, functional testing
  - 🔒 **Sensitive Data Filtering** - Built-in support for redacting secrets
  - 🎚️ **Multiple Recording Modes** - Flexible control over when to record/replay
  - 📦 **Multiple Interactions** - Store many request/response pairs in one cassette
  - 🎭 **Templating** - Parameterized cassettes for dynamic values (IDs, timestamps, etc.)
  - 🔀 **Cross-Process Support** - Explicit shared sessions for Task.async and GenServer

  ## Quick Start

      import ReqCassette

      test "fetches user data" do
        with_cassette "github_user", fn plug ->
          response = Req.get!("https://api.github.com/users/wojtekmach", plug: plug)
          assert response.status == 200
          assert response.body["login"] == "wojtekmach"
        end
      end

  **First run**: Records to `test/cassettes/github_user.json`
  **Subsequent runs**: Replays instantly from cassette (no network!)

  ## Upgrading

  > **⚠️ Migration guides for breaking changes:**
  >
  > - [v0.4 → v0.5](MIGRATION_V0.4_TO_V0.5.html) - Cross-process session support
  > - [v0.1 → v0.2](MIGRATION_V0.1_TO_V0.2.html) - API changes from v0.1

  ## Installation

  Add to your `mix.exs`:

      def deps do
        [
          {:req, "~> 0.5.15"},
          {:req_cassette, "~> 0.5.0"}
        ]
      end

  ## Recording Modes

  Control when to record and replay:

      # :record (default) - Record if cassette doesn't exist or interaction not found, otherwise replay
      with_cassette "api_call", [mode: :record], fn plug ->
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

      # To re-record a cassette: delete it first
      File.rm!("test/cassettes/api_call.json")
      with_cassette "api_call", [mode: :record], fn plug ->
        Req.get!("https://api.example.com/data", plug: plug)
      end

  ## Sensitive Data Filtering

  Protect API keys, tokens, and sensitive data:

      with_cassette "auth",
        [
          filter_request_headers: ["authorization", "x-api-key"],
          filter_response_headers: ["set-cookie"],
          filter_sensitive_data: [
            {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"}
          ],
          filter_request: fn request ->
            update_in(request, ["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
          end,
          filter_response: fn response ->
            update_in(response, ["body_json", "secret"], fn _ -> "<REDACTED>" end)
          end
        ],
        fn plug ->
          Req.post!("https://api.example.com/login", json: %{...}, plug: plug)
        end

  ReqCassette provides four filtering approaches for sensitive data protection:

  - **`filter_sensitive_data`** - Regex pattern replacement (fast, for common patterns)
  - **`filter_request_headers`** / **`filter_response_headers`** - Remove auth headers
  - **`filter_request`** - Custom request filtering (normalization, complex logic)
  - **`filter_response`** - Custom response filtering (always safe!)

  ### Filter Application Order

  When recording, filters are applied in this sequence:

  1. **Regex filters** → Request URI, query, body + Response body
  2. **Header filters** → Request headers + Response headers
  3. **Request callback** → Request only
  4. **Response callback** → Response only
  5. **Full callback** (`before_record`) → Entire interaction (advanced)

  This ensures simple filters run first, then targeted callbacks, and finally the
  advanced `before_record` hook sees the complete filtered result.

  **Note:** Only `filter_request` is also applied during replay matching to ensure
  requests match correctly. All other filters only run during recording.

  For detailed filtering documentation, see `ReqCassette.Filter`.

  ## Templating (Parameterized Cassettes)

  **Make one cassette handle multiple requests with different IDs, timestamps, or dynamic values.**

  Templating lets you extract dynamic values from requests/responses and replay cassettes
  with different values, perfect for testing APIs with varying identifiers.

  ### Quick Example

      # One cassette handles ALL product SKUs!
      test "product lookup with any SKU" do
        with_cassette "product_lookup",
          [
            template: [
              patterns: [sku: ~r/\\d{4}-\\d{4}/]
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

  ### How It Works

  1. **Extract** - Find dynamic values using regex patterns (`1234-5678`)
  2. **Template** - Replace with markers in cassette (`{{sku.0}}`)
  3. **Match** - Compare structure, not values during replay
  4. **Substitute** - Insert new values (`9999-8888`) when replaying

  ### Perfect For

  - **E-commerce APIs** - Product SKUs, order IDs
  - **User Management** - User IDs, email addresses
  - **LLM APIs** - Conversation IDs, request IDs, timestamps
  - **Pagination** - Cursor tokens, page numbers
  - **Time-sensitive APIs** - ISO timestamps, date ranges

  ### Common Patterns

      template: [
        patterns: [
          # Product SKUs
          sku: ~r/\\d{4}-\\d{4}/,

          # UUIDs
          uuid: ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,

          # Timestamps
          timestamp: ~r/\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z/,

          # LLM conversation IDs
          conversation_id: ~r/conv_[a-zA-Z0-9]+/
        ]
      ]

  ### LLM Example

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

  **📖 For comprehensive templating documentation, see the
  [Templating Guide](https://hexdocs.pm/req_cassette/guides/templating.html).**

  ## Cross-Process Requests (Task.async, GenServer, etc.)

  > **⚠️ Important:** If your tests make HTTP requests from spawned processes,
  > you need to use a shared session.

  By default, ReqCassette tracks request order using the process dictionary, which
  only works within a single process. If you spawn processes that make HTTP requests
  (e.g., `Task.async`, `Task.async_stream`, `GenServer`), each spawned process will
  independently start from interaction 0.

  ### The Problem

      # ❌ WITHOUT shared session - spawned processes don't share state
      with_cassette "parallel", fn plug ->
        tasks = for i <- 1..3 do
          Task.async(fn -> Req.get!("https://api.example.com/\#{i}", plug: plug) end)
        end
        Task.await_many(tasks)
        # Each task matches interaction 0 independently!
      end

  ### The Solution

  Use `start_shared_session/0` and `end_shared_session/1`:

      # ✅ WITH shared session - all processes share state
      session = ReqCassette.start_shared_session()
      try do
        with_cassette "parallel", [session: session], fn plug ->
          tasks = for i <- 1..3 do
            Task.async(fn -> Req.get!("https://api.example.com/\#{i}", plug: plug) end)
          end
          Task.await_many(tasks)
          # Tasks correctly get interactions 0, 1, 2 (in execution order)
        end
      after
        ReqCassette.end_shared_session(session)
      end

  ### When You Need Shared Sessions

  **Required for:**
  - `Task.async/1` or `Task.async_stream/3`
  - Requests from a `GenServer`
  - `spawn/1` or `spawn_link/1`
  - Any HTTP request from a different process

  **Not needed for:**
  - All requests from the same process (the common case)

  ### Convenience Options

  For simpler code, use `shared: true` or `with_shared_cassette/3`:

      # Option 1: shared: true shorthand
      with_cassette "parallel_test", [shared: true], fn plug ->
        tasks = for i <- 1..3 do
          Task.async(fn -> Req.get!("https://api.example.com/\#{i}", plug: plug) end)
        end
        Task.await_many(tasks)
      end

      # Option 2: with_shared_cassette helper
      with_shared_cassette "parallel_test", fn plug ->
        tasks = for i <- 1..3 do
          Task.async(fn -> Req.get!("https://api.example.com/\#{i}", plug: plug) end)
        end
        Task.await_many(tasks)
      end

  Both automatically manage the session lifecycle (start/end) for you.

  ### Best Practice: ExUnit Setup

  For multiple tests needing shared sessions, use ExUnit's setup:

      defmodule MyApp.ParallelAPITest do
        use ExUnit.Case, async: true
        import ReqCassette

        setup do
          session = ReqCassette.start_shared_session()
          on_exit(fn -> ReqCassette.end_shared_session(session) end)
          %{session: session}
        end

        test "parallel API calls", %{session: session} do
          with_cassette "parallel_test", [session: session], fn plug ->
            tasks = for i <- 1..3 do
              Task.async(fn -> Req.get!("https://api.example.com/\#{i}", plug: plug) end)
            end
            Task.await_many(tasks)
          end
        end
      end

  ## Advanced: before_record Hook

  **⚠️ ADVANCED - Use with Caution**

  The `:before_record` option provides full access to the interaction for cross-field
  manipulation. This is **NOT** for filtering - use `filter_request` and `filter_response`
  for that instead.

  ### ⚠️ Critical Warnings

  - **Avoid modifying request fields** - This will break replay matching!
  - **Use `filter_request` for request filtering** - Safer and applied during matching
  - **Use `filter_response` for response filtering** - Always safe
  - **Reserve `before_record` for special cases only** - When you need both request and response

  ### Safe Use Case: Response Enrichment

  Computing response fields based on request data:

      with_cassette "api_call",
        [
          before_record: fn interaction ->
            # ✅ SAFE: Only modifying response based on request
            request_id = interaction["request"]["body_json"]["id"]

            put_in(
              interaction,
              ["response", "body_json", "request_ref"],
              request_id
            )
          end
        ],
        fn plug ->
          Req.post!("https://api.example.com/process", json: %{id: 123}, plug: plug)
        end

  ### ⚠️ Dangerous Anti-Pattern

      with_cassette "api_call",
        [
          before_record: fn interaction ->
            # ❌ DANGER: Modifying request breaks replay matching!
            update_in(interaction, ["request", "body_json", "timestamp"], fn _ ->
              "<NORMALIZED>"
            end)
          end
        ],
        fn plug ->
          # This will fail on replay - request won't match saved cassette!
          Req.post!("https://api.example.com/data", json: %{...}, plug: plug)
        end

  **Instead, use `filter_request`:**

      with_cassette "api_call",
        [
          # ✅ CORRECT: filter_request is applied during both recording and matching
          filter_request: fn request ->
            update_in(request, ["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
          end
        ],
        fn plug ->
          Req.post!("https://api.example.com/data", json: %{...}, plug: plug)
        end

  ### When to Use before_record

  **Only** use `before_record` when you need to:
  - Compute derived fields from **both** request and response
  - Add metadata that references both sides of the interaction
  - Perform custom transformations that require full context

  **For everything else:**
  - Use `filter_sensitive_data` for regex patterns
  - Use `filter_request_headers` / `filter_response_headers` for auth headers
  - Use `filter_request` for request-only transformations
  - Use `filter_response` for response-only transformations

  ## Usage with ReqLLM

  Save money on LLM API calls during testing:

      test "LLM generation" do
        with_cassette "claude_response", fn plug ->
          {:ok, response} = ReqLLM.generate_text(
            "anthropic:claude-sonnet-4-20250514",
            "Explain recursion",
            max_tokens: 100,
            req_http_options: [plug: plug]
          )

          assert response.choices[0].message.content =~ "function calls itself"
        end
      end

  **First call**: Costs money (real API call)
  **Subsequent runs**: FREE (replays from cassette)

  ## Helper Functions

  Perfect for passing plug to reusable functions:

      defmodule MyApp.API do
        def fetch_user(id, opts \\\\ []) do
          Req.get!("https://api.example.com/users/\#{id}", plug: opts[:plug])
        end
      end

      test "user operations" do
        with_cassette "user_workflow", fn plug ->
          user = MyApp.API.fetch_user(1, plug: plug)
          assert user.body["id"] == 1
        end
      end

  ## Cassette Format v1.0

  Cassettes are stored as pretty-printed JSON with native JSON objects:

      {
        "version": "1.0",
        "interactions": [
          {
            "request": {
              "method": "GET",
              "uri": "https://api.example.com/users/1",
              "body_type": "text",
              "body": ""
            },
            "response": {
              "status": 200,
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

  Body types are automatically detected:
  - `json` - Stored as native JSON objects (pretty-printed, readable)
  - `text` - Plain text (HTML, XML, CSV)
  - `blob` - Binary data (images, PDFs) stored as base64

  ## Templating - Parameterized Cassettes

  ReqCassette supports **templating** to create parameterized cassettes that work with
  varying dynamic values (IDs, timestamps, SKUs, etc.) while maintaining the same
  response structure.

  ### Quick Example

      # One cassette handles ALL product SKUs!
      test "product lookup" do
        with_cassette "product",
          [template: [patterns: [sku: ~r/\\d{4}-\\d{4}/]]],
          fn plug ->
            # First call: records
            r1 = Req.get!("https://api.example.com/products/1234-5678", plug: plug)
            assert r1.body["sku"] == "1234-5678"

            # Second call: replays with DIFFERENT SKU!
            r2 = Req.get!("https://api.example.com/products/9999-8888", plug: plug)
            assert r2.body["sku"] == "9999-8888"  # ✅ Substituted!
          end
      end

  ### How It Works

  1. **Extract** - Find dynamic values using regex patterns (`1234-5678`)
  2. **Template** - Replace with markers in cassette (`{{sku.0}}`)
  3. **Match** - Compare structure (not values) during replay
  4. **Substitute** - Insert new values into response (`9999-8888`)

  ### Perfect For

  - E-commerce APIs (SKUs, order IDs)
  - LLM APIs (conversation IDs, request IDs)
  - Time-sensitive APIs (timestamps)
  - Pagination (cursor tokens)

  **📖 For comprehensive templating documentation, see the [Templating Guide](templating.html).**

  ## Documentation

  See `with_cassette/3` for the full API and configuration options.
  See `ReqCassette.Plug` for low-level plug interface.
  """

  @doc """
  Execute code with a cassette, providing the plug explicitly.

  Unlike `use_cassette/2` which auto-injects the plug, `with_cassette/3`
  provides the plug configuration as an argument to your function, giving
  you explicit control over where and how it's used.

  This is particularly useful for:
  - Passing plug to helper functions
  - Building reusable test utilities
  - Functional programming style
  - Clear visibility of what's being recorded

  ## Parameters

  - `name` - Human-readable cassette name (e.g., "github_user")
  - `opts` - Keyword list of options (optional)
  - `fun` - Function that takes the plug and returns a result

  ## Options

  - `:cassette_dir` - Directory where cassettes are stored (default: "test/cassettes")
  - `:mode` - Recording mode (default: `:record`)
    - `:replay` - Only replay from cassette, error if missing
    - `:record` - Record if cassette/interaction missing, otherwise replay
    - `:bypass` - Ignore cassettes, always hit network
  - `:match_requests_on` - List of matchers (default: `[:method, :uri, :query, :headers, :body]`)
    Available: `:method`, `:uri`, `:query`, `:headers`, `:body`
  - `:filter_sensitive_data` - List of `{pattern, replacement}` tuples for regex-based redaction
  - `:filter_request_headers` - List of header names to remove from requests
  - `:filter_response_headers` - List of header names to remove from responses
  - `:filter_request` - Callback to filter request data
  - `:filter_response` - Callback to filter response data
  - `:before_record` - Callback function to modify interaction before saving
  - `:template` - Template configuration for parameterized cassettes (keyword list):
    - `:patterns` - Keyword list of `{name, regex}` pairs (e.g., `[sku: ~r/\\d{4}-\\d{4}/]`)
    - `:allow_key_templates` - Allow JSON key templating (default: false)
  - `:sequential` - Enable sequential matching (default: `false`, automatically enabled with `:template`)
  - `:session` - Shared session reference for cross-process sequential matching (see below)
  - `:shared` - Shorthand for cross-process support (default: `false`). When `true`, automatically
    creates and manages a shared session. Equivalent to using `with_shared_cassette/3`.

  ## Matching Behavior

  **Default: First-Match** - Requests match the first interaction that matches the
  request criteria. Same request always returns same response. This is correct for
  most tests.

      with_cassette "api_test", fn plug ->
        Req.get!("/users/1", plug: plug)  # → Alice
        Req.get!("/users/2", plug: plug)  # → Bob
        Req.get!("/users/1", plug: plug)  # → Alice (same as first call)
      end

  **Sequential Matching** - Requests match interactions in order (request 1 → interaction 0,
  request 2 → interaction 1, etc.). Enable with `sequential: true` or `template: [...]`.

      # Polling API that returns different states over time
      with_cassette "polling_test", [sequential: true], fn plug ->
        Req.get!("/job/status", plug: plug)  # → {"status": "pending"}
        Req.get!("/job/status", plug: plug)  # → {"status": "running"}
        Req.get!("/job/status", plug: plug)  # → {"status": "completed"}
      end

  Sequential matching is essential for:
  - Identical requests expecting different responses (polling, state changes)
  - Templated cassettes where multiple requests have the same structure after templating
  - Nested `with_cassette` calls using the same cassette name

  ## Cross-Process Sequential Matching (Task.async, GenServer, etc.)

  When using sequential matching with spawned processes, the process dictionary
  can't be shared. Create a shared session:

      session = ReqCassette.start_shared_session()
      try do
        with_cassette "my_test", [session: session, sequential: true], fn plug ->
          # All requests share the session, even from spawned processes
          tasks = for i <- 1..3 do
            Task.async(fn ->
              Req.post!("https://api.example.com", plug: plug, json: %{id: i})
            end)
          end
          Task.await_many(tasks)
        end
      after
        ReqCassette.end_shared_session(session)
      end

  The shared session uses an Agent for cross-process state sharing. Without it,
  each spawned process would independently match from interaction 0.

  ## Returns

  The return value of the provided function.

  ## Examples

      # Basic usage
      with_cassette "github_user", fn plug ->
        Req.get!("https://api.github.com/users/wojtekmach", plug: plug)
      end

      # With options
      with_cassette "api_call",
        mode: :replay,
        match_requests_on: [:method, :uri],
        fn plug ->
          Req.get!("https://api.example.com/data", plug: plug)
        end

      # Pass plug to helper functions
      with_cassette "api_operations", fn plug ->
        user = MyApp.API.fetch_user(1, plug: plug)
        new_user = MyApp.API.create_user(%{name: "Bob"}, plug: plug)
        {user, new_user}
      end

      # Nested cassettes for different APIs
      with_cassette "github", fn github_plug ->
        user = Req.get!("https://api.github.com/users/alice", plug: github_plug)

        with_cassette "stripe", fn stripe_plug ->
          charge = Req.post!(
            "https://api.stripe.com/v1/charges",
            json: %{amount: 1000},
            plug: stripe_plug
          )

          {user, charge}
        end
      end

      # Filter sensitive data
      with_cassette "auth",
        filter_request_headers: ["authorization"],
        filter_sensitive_data: [
          {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"}
        ],
        fn plug ->
          Req.post!("https://api.example.com/login",
            json: %{username: "alice", password: "secret"},
            plug: plug)
        end

      # Cross-process requests with shared session
      session = ReqCassette.start_shared_session()
      try do
        with_cassette "parallel_api", [session: session], fn plug ->
          tasks = for i <- 1..3 do
            Task.async(fn -> Req.get!("https://api.example.com/\#{i}", plug: plug) end)
          end
          Task.await_many(tasks)
        end
      after
        ReqCassette.end_shared_session(session)
      end
  """
  @spec with_cassette(String.t(), keyword(), (plug :: term() -> result)) :: result
        when result: any()
  @spec with_cassette(String.t(), (plug :: term() -> result)) :: result
        when result: any()

  # 2-arity: with_cassette(name, fun)
  def with_cassette(name, fun) when is_function(fun, 1) do
    with_cassette(name, [], fun)
  end

  @doc """
  Creates a shared session for cross-process cassette matching.

  Use this when making HTTP requests from spawned processes (`Task.async`,
  `Task.async_stream`, `GenServer`, etc.). Pass the returned session to
  `with_cassette/3` via the `:session` option.

  Always call `end_shared_session/1` when done, preferably in an `after` block.

  ## Example

      session = ReqCassette.start_shared_session()
      try do
        with_cassette "my_test", [session: session, template: [preset: :common]], fn plug ->
          Task.async(fn -> Req.post!(..., plug: plug) end) |> Task.await()
        end
      after
        ReqCassette.end_shared_session(session)
      end

  ## Why is this needed?

  By default, sequential matching state is stored in the process dictionary,
  which is per-process. Spawned processes can't see or update the parent's state,
  so each would match from interaction 0.

  Shared sessions use an Agent process for cross-process state sharing, allowing all
  processes to coordinate sequential matching correctly.
  """
  @spec start_shared_session() :: pid()
  defdelegate start_shared_session(), to: ReqCassette.Session

  @doc """
  Ends a shared session by stopping its Agent process.

  Should be called in an `after` block to ensure cleanup even on errors.

  ## Example

      session = ReqCassette.start_shared_session()
      try do
        with_cassette "my_test", [session: session], fn plug -> ... end
      after
        ReqCassette.end_shared_session(session)
      end
  """
  @spec end_shared_session(pid()) :: :ok
  defdelegate end_shared_session(session), to: ReqCassette.Session

  @doc """
  Execute code with a cassette using a shared session for cross-process support.

  This is a convenience wrapper that handles the try/after boilerplate for shared
  sessions. Use this when your tests spawn processes that make HTTP requests
  (Task.async, GenServer, etc.).

  Equivalent to:

      session = ReqCassette.start_shared_session()
      try do
        with_cassette(name, Keyword.put(opts, :session, session), fun)
      after
        ReqCassette.end_shared_session(session)
      end

  ## Parameters

  - `name` - Human-readable cassette name
  - `opts` - Keyword list of options (same as `with_cassette/3`, but `:session` is auto-managed)
  - `fun` - Function that takes the plug and returns a result

  ## Example

      # Before (verbose):
      session = ReqCassette.start_shared_session()
      try do
        with_cassette "parallel_api", [session: session, template: [preset: :common]], fn plug ->
          tasks = for i <- 1..3 do
            Task.async(fn -> Req.get!("https://api.example.com/\#{i}", plug: plug) end)
          end
          Task.await_many(tasks)
        end
      after
        ReqCassette.end_shared_session(session)
      end

      # After (clean):
      with_shared_cassette "parallel_api", [template: [preset: :common]], fn plug ->
        tasks = for i <- 1..3 do
          Task.async(fn -> Req.get!("https://api.example.com/\#{i}", plug: plug) end)
        end
        Task.await_many(tasks)
      end

  ## When to Use

  Use `with_shared_cassette` when:
  - Using `Task.async/1` or `Task.async_stream/3`
  - Making requests from a GenServer
  - Using `spawn/1` or `spawn_link/1`
  - Any HTTP request from a different process

  For single-process tests, regular `with_cassette/3` is sufficient.
  """
  @spec with_shared_cassette(String.t(), keyword(), (plug :: term() -> result)) :: result
        when result: any()
  @spec with_shared_cassette(String.t(), (plug :: term() -> result)) :: result
        when result: any()

  def with_shared_cassette(name, fun) when is_function(fun, 1) do
    with_shared_cassette(name, [], fun)
  end

  def with_shared_cassette(name, opts, fun) when is_function(fun, 1) do
    session = start_shared_session()

    try do
      with_cassette(name, Keyword.put(opts, :session, session), fun)
    after
      end_shared_session(session)
    end
  end

  # 3-arity: with_cassette(name, opts, fun)
  def with_cassette(name, opts, fun) when is_function(fun, 1) do
    # Handle `shared: true` shorthand - delegates to with_shared_cassette
    if opts[:shared] == true do
      opts_without_shared = Keyword.delete(opts, :shared)
      with_shared_cassette(name, opts_without_shared, fun)
    else
      do_with_cassette(name, opts, fun)
    end
  end

  # Handle case where opts is omitted: with_cassette("name", fn plug -> ... end)
  def with_cassette(name, fun, []) when is_function(fun, 1) do
    with_cassette(name, [], fun)
  end

  defp do_with_cassette(name, opts, fun) do
    alias ReqCassette.{Cassette, Session}

    # Validate and process template options if present
    template_opts =
      if opts[:template] do
        validate_and_process_template_opts(opts[:template])
      else
        nil
      end

    cassette_dir = opts[:cassette_dir] || "test/cassettes"

    # Calculate cassette path for session tracking
    cassette_path = Path.join(cassette_dir, Cassette.sanitize_filename(name) <> ".json")

    # Sequential matching: enabled explicitly via `sequential: true` or implicitly via `template:`
    # When enabled, requests match interactions in order (request 1 → interaction 0, etc.)
    # When disabled (default), first-match is used (same request always gets same response)
    use_sequential = opts[:sequential] == true || template_opts != nil

    # Check for shared session (for cross-process matching)
    # If provided, uses Agent for cross-process state sharing
    # Otherwise, uses process dictionary (works for single-process tests)
    shared_session = opts[:session]

    # Start session only if sequential matching is enabled
    session_id =
      if use_sequential do
        Session.start_session(cassette_path, shared_session)
      else
        nil
      end

    plug_opts = %{
      cassette_name: name,
      cassette_dir: cassette_dir,
      mode: opts[:mode] || :record,
      match_requests_on: opts[:match_requests_on] || [:method, :uri, :query, :headers, :body],
      filter_sensitive_data: opts[:filter_sensitive_data] || [],
      filter_request_headers: opts[:filter_request_headers] || [],
      filter_response_headers: opts[:filter_response_headers] || [],
      filter_request: opts[:filter_request],
      filter_response: opts[:filter_response],
      before_record: opts[:before_record],
      template: template_opts,
      session_id: session_id
    }

    plug = {ReqCassette.Plug, plug_opts}

    try do
      fun.(plug)
    after
      # End session if one was started (only for sequential matching)
      if session_id do
        Session.end_session(cassette_path, session_id)
      end
    end
  end

  # Private helpers

  defp validate_and_process_template_opts(template_opts) when is_list(template_opts) do
    preset_patterns = resolve_preset_patterns(template_opts[:preset])
    explicit_patterns = validate_explicit_patterns(template_opts[:patterns])

    validate_template_requirements(template_opts)

    merged_patterns = Keyword.merge(preset_patterns, explicit_patterns)
    validate_pattern_types(merged_patterns)

    %{
      patterns: Map.new(merged_patterns),
      allow_key_templates: template_opts[:allow_key_templates] || false,
      debug: template_opts[:debug] || false
    }
  end

  defp validate_and_process_template_opts(invalid) do
    raise ArgumentError, """
    Template options must be a keyword list.

    Got: #{inspect(invalid)}

    Examples:
      template: [preset: :anthropic]
      template: [patterns: [sku: ~r/\\d{4}-\\d{4}/]]
      template: [preset: :llm, patterns: [order_id: ~r/ORD-\\d+/]]
    """
  end

  defp resolve_preset_patterns(nil), do: []

  defp resolve_preset_patterns(preset_name) when is_atom(preset_name) do
    alias ReqCassette.Template.Presets

    case Presets.get(preset_name) do
      {:ok, patterns} ->
        patterns

      {:error, {:unknown_preset, name}} ->
        raise ArgumentError, """
        Unknown template preset: #{inspect(name)}

        Available presets: #{inspect(Presets.available())}

        Example usage:
          template: [preset: :anthropic]
          template: [preset: :llm]
        """
    end
  end

  defp resolve_preset_patterns(invalid_preset) do
    alias ReqCassette.Template.Presets

    raise ArgumentError, """
    Template :preset must be an atom.

    Got: #{inspect(invalid_preset)}

    Available presets: #{inspect(Presets.available())}
    """
  end

  defp validate_explicit_patterns(nil), do: []
  defp validate_explicit_patterns([]), do: []

  defp validate_explicit_patterns(patterns) do
    unless is_list(patterns) && Keyword.keyword?(patterns) do
      raise ArgumentError, """
      Template :patterns must be a keyword list of {name, regex} pairs.

      Example:
        template: [
          patterns: [
            sku: ~r/\\d{4}-\\d{4}/,
            order_id: ~r/ORD-\\d+/
          ]
        ]
      """
    end

    patterns
  end

  defp validate_template_requirements(template_opts) do
    alias ReqCassette.Template.Presets

    has_preset = template_opts[:preset] != nil
    has_patterns_key = Keyword.has_key?(template_opts, :patterns)

    unless has_preset || has_patterns_key do
      raise ArgumentError, """
      Template requires either :preset or :patterns (or both).

      Examples:
        # Using a preset
        template: [preset: :anthropic]

        # Using custom patterns
        template: [patterns: [sku: ~r/\\d{4}-\\d{4}/]]

        # Combining preset with custom patterns
        template: [preset: :anthropic, patterns: [order_id: ~r/ORD-\\d+/]]

      Available presets: #{inspect(Presets.available())}
      """
    end
  end

  defp validate_pattern_types(patterns) do
    Enum.each(patterns, fn {name, pattern} ->
      unless is_atom(name) do
        raise ArgumentError,
              "Template pattern name must be an atom, got: #{inspect(name)}"
      end

      unless is_struct(pattern, Regex) do
        raise ArgumentError,
              "Template pattern #{inspect(name)} must be a Regex, got: #{inspect(pattern)}"
      end
    end)
  end
end
