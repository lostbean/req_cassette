defmodule ReqCassette.Filter do
  @moduledoc """
  Filters sensitive data from cassette interactions before saving.

  This module provides comprehensive filtering capabilities to remove or redact sensitive
  information (API keys, tokens, passwords, etc.) from cassette files before they're saved.
  This ensures that cassettes can be safely committed to version control without exposing secrets.

  ## Why Filter Cassettes?

  Cassettes record real HTTP interactions, which often contain sensitive data:

  - API keys in query strings or headers
  - Authentication tokens in request/response bodies
  - Session cookies in response headers
  - Personal information (emails, names, addresses)
  - Internal URLs or infrastructure details

  Filtering prevents these secrets from being committed to your repository.

  ## Filtering Types

  ReqCassette supports four complementary filtering approaches:

  ### 1. Regex-Based Replacement ✅ Recommended for patterns

  Replace patterns in URIs, query strings, and request/response bodies using regular expressions:

      filters = [
        filter_sensitive_data: [
          {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"},
          {~r/"token":"[^"]+"/, ~s("token":"<REDACTED>")},
          {~r/Bearer [\\w.-]+/, "Bearer <REDACTED>"}
        ]
      ]

  **Features:**
  - Applied to URIs, query strings, and all body types
  - Works with both string and JSON bodies
  - For JSON bodies, tries pattern matching on serialized form first, then recursive matching
  - Multiple patterns processed in order

  **Common patterns:**
  ```elixir
  # API keys
  {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"}
  {~r/"apiKey":"[^"]+"/, ~s("apiKey":"<REDACTED>")}

  # Tokens
  {~r/Bearer [\\w.-]+/, "Bearer <REDACTED>"}
  {~r/"token":"[^"]+"/, ~s("token":"<REDACTED>")}

  # Email addresses
  {~r/[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,}/, "user@example.com"}

  # Credit cards
  {~r/\\d{4}[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{4}/, "XXXX-XXXX-XXXX-XXXX"}

  # UUIDs (for consistent cassettes)
  {~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
  ```

  ### 2. Header Removal ✅ Recommended for auth headers

  Remove sensitive headers from requests and responses:

      filters = [
        filter_request_headers: ["authorization", "x-api-key", "cookie"],
        filter_response_headers: ["set-cookie", "x-secret-token"]
      ]

  **Features:**
  - Case-insensitive matching (`Authorization` matches `authorization`)
  - Completely removes headers from cassette
  - Separate lists for request and response headers

  ### 3. Request Callback Filtering ✅ Safe for complex request filtering

  Target request-only filtering with custom logic:

      filters = [
        filter_request: fn request ->
          request
          |> update_in(["body_json", "email"], fn _ -> "redacted@example.com" end)
          |> update_in(["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
        end
      ]

  **Features:**
  - Applied during BOTH recording and matching (like regex/header filters)
  - Only receives request portion of interaction
  - Safe for complex request transformations

  **⚠️ Important:** If `filter_request` modifies fields used for matching
  (method, uri, query, headers, body), consider adjusting `match_requests_on`
  to exclude those fields, or ensure transformations are idempotent.

  **When to use:**
  - Complex request body transformations
  - Conditional filtering based on request fields
  - Normalization that can't be expressed as regex

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

  ### 4. Response Callback Filtering ✅ Always safe

  Target response-only filtering:

      filters = [
        filter_response: fn response ->
          response
          |> update_in(["body_json", "secret"], fn _ -> "<REDACTED>" end)
          |> update_in(["headers", "set-cookie"], fn _ -> ["<REDACTED>"] end)
        end
      ]

  **Features:**
  - Applied ONLY during recording
  - Only receives response portion of interaction
  - Always safe - responses don't affect matching
  - Simplest callback type

  **When to use:**
  - Response-only filtering
  - Complex response transformations
  - Conditional filtering based on response data

  **Response structure:**
  ```elixir
  %{
    "status" => 200,
    "headers" => %{},
    "body_type" => "json",
    "body_json" => %{}  # or "body" for text, "body_blob" for binary
  }
  ```

  ## Filter Application Order

  Filters are applied in this specific order during recording:

  1. **Regex filters** (`filter_sensitive_data`) - Applied to:
     - Request URI
     - Request query_string
     - Request body (all types: json, text, blob)
     - Response body (all types: json, text, blob)

  2. **Header filters** - Applied to:
     - Request headers (`filter_request_headers`)
     - Response headers (`filter_response_headers`)

  3. **Request callback** (`filter_request`) - Applied to:
     - Request only (entire request object)

  4. **Response callback** (`filter_response`) - Applied to:
     - Response only (entire response object)

  5. **Full interaction callback** (`before_record`) - Applied to:
     - Entire interaction (both request AND response)
     - See main module docs for warnings about this advanced option

  This ordering ensures coarse-grained filters (regex, headers) run first, then
  specific callbacks (request/response), and finally the advanced `before_record`
  can access the complete filtered result.

  ## Choosing the Right Filter Type

  | Need                               | Recommended Approach            |
  |------------------------------------|---------------------------------|
  | Remove auth headers                | ✅ `filter_request_headers`     |
  | Redact API keys in URLs            | ✅ `filter_sensitive_data`      |
  | Redact tokens in JSON              | ✅ `filter_sensitive_data`      |
  | Complex request normalization      | ✅ `filter_request`             |
  | Complex response filtering         | ✅ `filter_response`            |

  ## Usage

      # Typically used via with_cassette/3
      ReqCassette.with_cassette(
        "api_call",
        [
          # Regex patterns (fastest)
          filter_sensitive_data: [
            {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"}
          ],

          # Header removal
          filter_request_headers: ["authorization"],
          filter_response_headers: ["set-cookie"],

          # Request filtering (custom logic)
          filter_request: fn request ->
            update_in(request, ["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
          end,

          # Response filtering (always safe!)
          filter_response: fn response ->
            update_in(response, ["body_json", "secret"], fn _ -> "<REDACTED>" end)
          end
        ],
        fn plug ->
          Req.get!("https://api.example.com/data?api_key=secret123", plug: plug)
        end
      )

      # Can also be used directly (internal API)
      filtered_interaction = ReqCassette.Filter.apply_filters(interaction, opts)

  ## Examples

      # Filter API keys from query strings
      ReqCassette.with_cassette(
        "github_api",
        [
          filter_sensitive_data: [
            {~r/access_token=[\\w-]+/, "access_token=<REDACTED>"}
          ]
        ],
        fn plug ->
          Req.get!("https://api.github.com/user?access_token=gho_abc123", plug: plug)
        end
      )
      # Cassette will contain: ?access_token=<REDACTED>

      # Remove authorization headers
      ReqCassette.with_cassette(
        "authenticated_api",
        [filter_request_headers: ["authorization"]],
        fn plug ->
          Req.get!(
            "https://api.example.com/data",
            headers: [{"authorization", "Bearer secret"}],
            plug: plug
          )
        end
      )
      # Cassette won't contain the authorization header

      # Filter tokens from JSON responses
      ReqCassette.with_cassette(
        "login",
        [
          filter_sensitive_data: [
            {~r/"access_token":"[^"]+"/, ~s("access_token":"<REDACTED>")},
            {~r/"refresh_token":"[^"]+"/, ~s("refresh_token":"<REDACTED>")}
          ]
        ],
        fn plug ->
          Req.post!("https://auth.example.com/login", json: %{...}, plug: plug)
        end
      )
      # Tokens in response JSON are redacted

      # Filter request with custom callback
      ReqCassette.with_cassette(
        "normalized_request",
        [
          filter_request: fn request ->
            request
            # Normalize timestamp for consistent matching
            |> update_in(["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
            # Redact email in request
            |> update_in(["body_json", "email"], fn _ -> "user@example.com" end)
          end
        ],
        fn plug ->
          Req.post!(
            "https://api.example.com/events",
            json: %{event: "login", timestamp: DateTime.utc_now(), email: "alice@example.com"},
            plug: plug
          )
        end
      )

      # Filter response with custom callback
      ReqCassette.with_cassette(
        "user_profile",
        [
          filter_response: fn response ->
            response
            # Redact email
            |> update_in(["body_json", "email"], fn _ -> "user@example.com" end)
            # Redact phone
            |> update_in(["body_json", "phone"], fn _ -> "555-0000" end)
            # Remove credit card completely
            |> update_in(["body_json"], &Map.delete(&1, "credit_card"))
          end
        ],
        fn plug ->
          Req.get!("https://api.example.com/profile", plug: plug)
        end
      )

      # Combine all filter types
      ReqCassette.with_cassette(
        "complete_example",
        [
          # Regex filters for patterns
          filter_sensitive_data: [
            {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"},
            {~r/"token":"[^"]+"/, ~s("token":"<REDACTED>")}
          ],
          # Header filters
          filter_request_headers: ["authorization", "cookie"],
          filter_response_headers: ["set-cookie", "x-api-key"],
          # Request callback for normalization
          filter_request: fn request ->
            update_in(request, ["body_json", "timestamp"], fn _ -> "<NORMALIZED>" end)
          end,
          # Response callback for redaction
          filter_response: fn response ->
            update_in(response, ["body_json", "user", "email"], fn _ ->
              "redacted@example.com"
            end)
          end
        ],
        fn plug ->
          Req.post!("https://api.example.com/data", json: %{...}, plug: plug)
        end
      )

  ## JSON Body Handling

  For JSON bodies, regex filters are applied intelligently:

  1. First, try matching the pattern on the serialized JSON string
  2. If it matches, replace and attempt to parse back
  3. If parsing fails or pattern doesn't match, apply recursively to values

  This allows patterns like `~r/"token":"[^"]+"` to match the JSON structure directly,
  while also supporting value-level patterns like `~r/secret_value/`.

  ## Best Practices

  - **Commit filtered cassettes** - Always filter before committing to version control
  - **Use regex for patterns** - API keys, tokens, and structured secrets
  - **Use headers for credentials** - Remove Authorization, Cookie headers
  - **Use filter_request for request normalization** - Timestamps, IDs, request-specific data
  - **Use filter_response for response redaction** - Safe and simple for all response filtering
  - **Test your filters** - Manually inspect cassettes after filtering
  - **Document patterns** - Comment your regex patterns for maintainability
  - **Be cautious with filter_request** - Ensure transformations are idempotent or adjust match_requests_on

  ## See Also

  - `ReqCassette` - Main module with examples
  - `ReqCassette.Cassette` - Cassette format and interaction structure
  """

  @doc """
  Applies all configured filters to an interaction before saving.

  ## Parameters

  - `interaction` - The cassette interaction map
  - `opts` - Filter options from cassette configuration
    - `:filter_sensitive_data` - List of `{regex, replacement}` tuples
    - `:filter_request_headers` - List of header names to remove from requests
    - `:filter_response_headers` - List of header names to remove from responses
    - `:filter_request` - Callback function `(request -> request)` for request-only filtering
    - `:filter_response` - Callback function `(response -> response)` for response-only filtering

  ## Filter Application Order

  1. **Regex filters** - Applied to URI, query string, request body, response body
  2. **Header filters** - Remove specified request/response headers
  3. **Request callback** (filter_request) - Transform request
  4. **Response callback** (filter_response) - Transform response

  ## Returns

  Filtered interaction map

  ## Note

  This function also supports the advanced `:before_record` option for backward compatibility
  and special use cases. See `ReqCassette` module documentation for details on when to use it.
  """
  @spec apply_filters(map(), map()) :: map()
  def apply_filters(interaction, opts) do
    interaction
    |> apply_regex_filters(opts[:filter_sensitive_data] || [])
    |> apply_header_filters(
      opts[:filter_request_headers] || [],
      opts[:filter_response_headers] || []
    )
    |> apply_request_callback(opts[:filter_request])
    |> apply_response_callback(opts[:filter_response])
    |> apply_callback(opts[:before_record])
  end

  @doc """
  Applies only response-related filters to an interaction.

  Use this when the request has already been filtered at an earlier stage
  (e.g., in the plug before matching). This prevents non-idempotent filters
  from being applied twice to requests.

  ## Filters Applied

  - Regex filters (`filter_sensitive_data`) - response body only
  - Header filters (`filter_response_headers`) - response headers only
  - Response callback (`filter_response`)
  - Before record callback (`before_record`)

  ## Filters NOT Applied

  - Regex filters on request (already done)
  - Header filters on request headers (already done)
  - Request callback (`filter_request`) (already done)
  """
  @spec apply_response_only_filters(map(), map()) :: map()
  def apply_response_only_filters(interaction, opts) do
    interaction
    |> apply_regex_filters_response_only(opts[:filter_sensitive_data] || [])
    |> apply_response_header_filters(opts[:filter_response_headers] || [])
    |> apply_response_callback(opts[:filter_response])
    |> apply_callback(opts[:before_record])
  end

  # Regex filters applied to response only (request already filtered)
  defp apply_regex_filters_response_only(interaction, patterns) do
    Enum.reduce(patterns, interaction, fn {pattern, replacement}, acc ->
      # Only apply to response body (request already filtered at entry point)
      update_body_in(acc, ["response"], fn body ->
        apply_regex_to_body(body, pattern, replacement)
      end)
    end)
  end

  # Header filters applied to response only
  defp apply_response_header_filters(interaction, response_headers) do
    update_in(interaction, ["response", "headers"], fn headers ->
      remove_headers(headers, response_headers)
    end)
  end

  # Regex-based pattern replacement
  defp apply_regex_filters(interaction, patterns) do
    Enum.reduce(patterns, interaction, fn {pattern, replacement}, acc ->
      acc
      # Apply to request body
      |> update_body_in(["request"], fn body ->
        apply_regex_to_body(body, pattern, replacement)
      end)
      # Apply to response body
      |> update_body_in(["response"], fn body ->
        apply_regex_to_body(body, pattern, replacement)
      end)
      # Also apply to URI and query_string
      |> update_in(["request", "uri"], fn uri ->
        if uri, do: Regex.replace(pattern, uri, replacement), else: uri
      end)
      |> update_in(["request", "query_string"], fn qs ->
        if qs, do: Regex.replace(pattern, qs, replacement), else: qs
      end)
    end)
  end

  defp apply_regex_to_body(body, pattern, replacement) do
    cond do
      is_binary(body) ->
        Regex.replace(pattern, body, replacement)

      is_map(body) or is_list(body) ->
        # For JSON bodies, try two approaches:
        # 1. Apply directly to values (for patterns like /value/)
        # 2. Apply to serialized JSON (for patterns like /"key":"value"/)

        # First, try serializing to JSON and applying the pattern
        json = Jason.encode!(body)

        if Regex.match?(pattern, json) do
          # Pattern matches the JSON format, so replace in serialized form
          replaced = Regex.replace(pattern, json, replacement)

          # Try to parse back
          case Jason.decode(replaced) do
            {:ok, decoded} -> decoded
            {:error, _} -> body
          end
        else
          # Pattern doesn't match JSON format, apply recursively to values
          apply_regex_recursively(body, pattern, replacement)
        end

      true ->
        body
    end
  end

  defp apply_regex_recursively(body, pattern, replacement) when is_map(body) do
    Map.new(body, fn {key, value} ->
      new_value =
        cond do
          is_binary(value) -> Regex.replace(pattern, value, replacement)
          is_map(value) -> apply_regex_recursively(value, pattern, replacement)
          is_list(value) -> Enum.map(value, &apply_regex_recursively(&1, pattern, replacement))
          true -> value
        end

      {key, new_value}
    end)
  end

  defp apply_regex_recursively(body, pattern, replacement) when is_list(body) do
    Enum.map(body, &apply_regex_recursively(&1, pattern, replacement))
  end

  defp apply_regex_recursively(body, pattern, replacement) when is_binary(body) do
    Regex.replace(pattern, body, replacement)
  end

  defp apply_regex_recursively(body, _pattern, _replacement), do: body

  # Header removal/redaction
  defp apply_header_filters(interaction, request_headers, response_headers) do
    interaction
    |> update_in(["request", "headers"], fn headers ->
      remove_headers(headers, request_headers)
    end)
    |> update_in(["response", "headers"], fn headers ->
      remove_headers(headers, response_headers)
    end)
  end

  defp remove_headers(headers, headers_to_remove) do
    lowercase_remove = Enum.map(headers_to_remove, &String.downcase/1)

    Enum.reject(headers, fn {key, _value} ->
      String.downcase(key) in lowercase_remove
    end)
    |> Enum.into(%{})
  end

  # Request-only callback filtering
  defp apply_request_callback(interaction, nil), do: interaction

  defp apply_request_callback(interaction, callback) when is_function(callback, 1) do
    update_in(interaction, ["request"], callback)
  end

  defp apply_request_callback(interaction, _), do: interaction

  # Response-only callback filtering
  defp apply_response_callback(interaction, nil), do: interaction

  defp apply_response_callback(interaction, callback) when is_function(callback, 1) do
    update_in(interaction, ["response"], callback)
  end

  defp apply_response_callback(interaction, _), do: interaction

  # Full interaction callback filtering
  defp apply_callback(interaction, nil), do: interaction

  defp apply_callback(interaction, callback) when is_function(callback, 1) do
    callback.(interaction)
  end

  defp apply_callback(interaction, _), do: interaction

  # Helper to update body fields regardless of body type
  defp update_body_in(interaction, path, fun) do
    # Body could be in "body", "body_json", or "body_blob"
    cond do
      get_in(interaction, path ++ ["body"]) ->
        update_in(interaction, path ++ ["body"], fun)

      get_in(interaction, path ++ ["body_json"]) ->
        update_in(interaction, path ++ ["body_json"], fun)

      get_in(interaction, path ++ ["body_blob"]) ->
        # For blob, decode, apply filter, re-encode
        update_in(interaction, path ++ ["body_blob"], fn blob ->
          decoded = Base.decode64!(blob)
          filtered = fun.(decoded)
          Base.encode64(filtered)
        end)

      true ->
        interaction
    end
  end
end
