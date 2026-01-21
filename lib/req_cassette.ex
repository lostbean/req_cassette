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

  ## Upgrading from v0.1

  > **⚠️ Important:** v0.2.0 introduces breaking changes to improve the API and cassette format.
  > See the [Migration Guide](https://hexdocs.pm/req_cassette/migration_v0.1_to_v0.2.html) for upgrade instructions.

  **Key changes:**
  - New `with_cassette/3` API (replaces direct plug usage)
  - Cassette format v1.0 with multiple interactions
  - Human-readable cassette filenames
  - Pretty-printed JSON (40% smaller, much more readable)

  **Migration time:** ~15-30 minutes for most projects

  ## Installation

  Add to your `mix.exs`:

      def deps do
        [
          {:req, "~> 0.5.15"},
          {:req_cassette, "~> 0.2.0"}
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
  """
  @spec with_cassette(String.t(), keyword(), (plug :: term() -> result)) :: result
        when result: any()
  @spec with_cassette(String.t(), (plug :: term() -> result)) :: result
        when result: any()

  # 2-arity: with_cassette(name, fun)
  def with_cassette(name, fun) when is_function(fun, 1) do
    with_cassette(name, [], fun)
  end

  # 3-arity: with_cassette(name, opts, fun)
  def with_cassette(name, opts, fun) when is_function(fun, 1) do
    # Validate and process template options if present
    template_opts =
      if opts[:template] do
        validate_and_process_template_opts(opts[:template])
      else
        nil
      end

    plug_opts = %{
      cassette_name: name,
      cassette_dir: opts[:cassette_dir] || "test/cassettes",
      mode: opts[:mode] || :record,
      match_requests_on: opts[:match_requests_on] || [:method, :uri, :query, :headers, :body],
      filter_sensitive_data: opts[:filter_sensitive_data] || [],
      filter_request_headers: opts[:filter_request_headers] || [],
      filter_response_headers: opts[:filter_response_headers] || [],
      filter_request: opts[:filter_request],
      filter_response: opts[:filter_response],
      before_record: opts[:before_record],
      template: template_opts
    }

    plug = {ReqCassette.Plug, plug_opts}
    fun.(plug)
  end

  def with_cassette(name, fun, []) when is_function(fun, 1) do
    # Handle case where opts is omitted: with_cassette("name", fn plug -> ... end)
    with_cassette(name, [], fun)
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
