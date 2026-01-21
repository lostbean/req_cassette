defmodule ReqCassette.Cassette do
  @moduledoc """
  Handles cassette file format v1.0 with multiple interactions per file.

  This module provides the core functionality for creating, loading, saving, and searching
  cassette files. Cassettes store HTTP request/response pairs ("interactions") in a
  human-readable JSON format.

  ## Cassette Format v1.0

  Each cassette file contains a version field and an array of interactions:

  ```json
  {
    "version": "1.0",
    "interactions": [
      {
        "request": {
          "method": "GET",
          "uri": "https://api.example.com/users/1",
          "query_string": "filter=active",
          "headers": {
            "accept": ["application/json"],
            "user-agent": ["req/0.5.15"]
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
        "recorded_at": "2025-10-16T14:23:45.123456Z"
      }
    ]
  }
  ```

  ## Key Features

  ### Multiple Interactions Per Cassette

  Multiple interactions can be stored in a single cassette file with human-readable names:

      # All requests in one test go to one cassette
      ReqCassette.with_cassette("user_workflow", [], fn plug ->
        user = Req.get!("/users/1", plug: plug)      # Interaction 1
        posts = Req.get!("/posts", plug: plug)       # Interaction 2
        comments = Req.get!("/comments", plug: plug) # Interaction 3
      end)
      # Creates: user_workflow.json with 3 interactions

  Benefits:
  - Related requests grouped together
  - Meaningful filenames
  - Logical workflow organization

  ### Body Type Discrimination

  Bodies are stored in one of three formats based on content type:

  - `body_json` - JSON responses stored as native Elixir data structures
  - `body` - Text responses (HTML, XML, CSV) stored as strings
  - `body_blob` - Binary data (images, PDFs) base64-encoded

  Example JSON storage:
  ```json
  "body_json": {
    "id": 1,
    "name": "Alice"
  }
  ```

  Benefits:
  - Compact cassette files
  - No double-encoding/escaping
  - Human-readable JSON responses
  - Easy to edit or debug

  ### Pretty-Printed JSON

  All cassettes are saved with `Jason.encode!(cassette, pretty: true)` for:

  - Git-friendly diffs
  - Easy manual inspection
  - Debuggability
  - Version control readability

  ### Request Matching with Normalization

  Requests are matched using configurable criteria with automatic normalization:

  - Query parameters are order-independent: `?a=1&b=2` matches `?b=2&a=1`
  - JSON body keys are order-independent: `{"a":1,"b":2}` matches `{"b":2,"a":1}`
  - Headers are case-insensitive: `Accept` matches `accept`

  ## Examples

      # Create a new cassette
      cassette = ReqCassette.Cassette.new()
      #=> %{"version" => "1.0", "interactions" => []}

      # Add an interaction
      cassette = add_interaction(cassette, conn, request_body, response)

      # Save to disk (pretty-printed)
      save("test/cassettes/my_api.json", cassette)

      # Load from disk
      {:ok, cassette} = load("test/cassettes/my_api.json")

      # Find a matching interaction
      case find_interaction(cassette, conn, body, [:method, :uri]) do
        {:ok, response} -> response
        :not_found -> # Record new interaction
      end

      # Multiple interactions in one cassette
      cassette = new()
      cassette = add_interaction(cassette, conn1, body1, resp1)
      cassette = add_interaction(cassette, conn2, body2, resp2)
      cassette = add_interaction(cassette, conn3, body3, resp3)
      save("workflow.json", cassette)
      # workflow.json now contains 3 interactions

  ## See Also

  - `ReqCassette.BodyType` - Body type detection and encoding
  - `ReqCassette.Filter` - Sensitive data filtering
  - `ReqCassette.Plug` - Main plug that uses this module
  """

  alias ReqCassette.BodyType
  alias ReqCassette.Filter
  alias ReqCassette.Template.Debug
  alias ReqCassette.Template.Extractor
  alias ReqCassette.Template.Matcher
  alias ReqCassette.Template.Normalizer
  alias ReqCassette.Template.Replacer

  @version "2.0"

  @typedoc "A cassette file containing multiple interactions"
  @type t :: %{
          version: String.t(),
          interactions: [interaction()]
        }

  @typedoc "A single HTTP request/response interaction"
  @type interaction :: %{
          request: request(),
          response: response(),
          recorded_at: String.t()
        }

  @typedoc "HTTP request details"
  @type request :: %{
          method: String.t(),
          uri: String.t(),
          query_string: String.t(),
          headers: map(),
          body_type: String.t()
        }

  @typedoc "HTTP response details"
  @type response :: %{
          status: integer(),
          headers: map(),
          body_type: String.t()
        }

  @doc """
  Creates a new empty cassette with version 1.0.

  ## Examples

      new()
      # => %{version: "1.0", interactions: []}
  """
  @spec new() :: map()
  def new do
    %{
      "version" => @version,
      "interactions" => []
    }
  end

  @doc """
  Adds an interaction to a cassette.

  Creates a new interaction from the given request and response, applies any configured
  filters, and appends it to the cassette's interactions array.

  ## Parameters

  - `cassette` - The cassette map (from `new/0` or `load/1`)
  - `conn` - The `Plug.Conn` struct with request details (method, URI, headers, etc.)
  - `request_body` - The raw request body as a binary string
  - `response` - The `Req.Response` struct from the HTTP call
  - `opts` - Optional map of filter options (default: `%{}`)

  ## Filter Options

  The `opts` parameter can include:

  - `:filter_sensitive_data` - List of `{regex, replacement}` tuples
  - `:filter_request_headers` - List of header names to remove from requests
  - `:filter_response_headers` - List of header names to remove from responses
  - `:before_record` - Callback function `(interaction -> interaction)`

  See `ReqCassette.Filter` for details on filtering.

  ## Returns

  Updated cassette map with the new interaction appended to the `"interactions"` array.

  ## Body Type Detection

  This function automatically detects the body type for both request and response:

  - JSON bodies are stored in `body_json` field as native Elixir data structures
  - Text bodies (HTML, XML, CSV) are stored in `body` field as strings
  - Binary bodies (images, PDFs) are base64-encoded in `body_blob` field

  ## Timestamp

  Each interaction includes a `recorded_at` field with an ISO8601 UTC timestamp
  indicating when the interaction was captured.

  ## Examples

      # Basic usage
      cassette = new()
      cassette = add_interaction(cassette, conn, "", response)

      # With filtering
      opts = %{
        filter_sensitive_data: [
          {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"}
        ],
        filter_request_headers: ["authorization"]
      }
      cassette = add_interaction(cassette, conn, body, response, opts)

      # Multiple interactions
      cassette = new()
      cassette = add_interaction(cassette, conn1, body1, resp1)
      cassette = add_interaction(cassette, conn2, body2, resp2)
      cassette = add_interaction(cassette, conn3, body3, resp3)
      # cassette now has 3 interactions

      # With callback filter
      opts = %{
        before_record: fn interaction ->
          put_in(interaction, ["response", "body_json", "secret"], "<REDACTED>")
        end
      }
      cassette = add_interaction(cassette, conn, body, response, opts)
  """
  # New signature: accepts pre-filtered request map
  @spec add_interaction(map(), map(), Req.Response.t(), map()) :: map()
  def add_interaction(cassette, filtered_request, response, opts)
      when is_map(filtered_request) and is_struct(response) do
    # Build interaction from already-filtered request
    interaction = build_interaction_from_filtered(filtered_request, response)

    # Apply only response filters (request already filtered at entry point)
    # This prevents non-idempotent request filters from running twice
    filtered_interaction = Filter.apply_response_only_filters(interaction, opts)

    # Apply templates if configured
    final_interaction =
      if opts[:template] do
        apply_template_to_interaction(filtered_interaction, opts[:template])
      else
        filtered_interaction
      end

    Map.update!(cassette, "interactions", fn interactions ->
      interactions ++ [final_interaction]
    end)
  end

  # Backward compatibility: old signature with conn and body
  def add_interaction(cassette, %Plug.Conn{} = conn, request_body, response, opts \\ %{}) do
    # Build interaction the old way
    interaction = build_interaction(conn, request_body, response)

    # Apply filters BEFORE template extraction (critical!)
    filtered_interaction = Filter.apply_filters(interaction, opts)

    # Apply templates if configured
    final_interaction =
      if opts[:template] do
        apply_template_to_interaction(filtered_interaction, opts[:template])
      else
        filtered_interaction
      end

    Map.update!(cassette, "interactions", fn interactions ->
      interactions ++ [final_interaction]
    end)
  end

  @doc """
  Finds a matching interaction in the cassette based on request matching criteria.

  Searches through all interactions in the cassette to find one where the request
  matches the given `conn` and `body` according to the specified matchers. Returns
  the first matching interaction's response.

  ## Parameters

  - `cassette` - The cassette map (loaded from `load/1` or created with `new/0`)
  - `conn` - The `Plug.Conn` struct representing the current request
  - `request_body` - The raw request body as a binary string
  - `match_on` - List of matchers that determine matching criteria

  ## Matchers

  The `match_on` parameter accepts a list of atoms that specify what to match:

  - `:method` - HTTP method (GET, POST, etc.) - case-insensitive
  - `:uri` - Full URI including scheme, host, port, and path
  - `:query` - Query parameters - order-independent
  - `:headers` - Request headers - case-insensitive, order-independent
  - `:body` - Request body - JSON bodies are order-independent

  **Common matching strategies:**

  - `[:method, :uri]` - Match only method and path (ignore query, headers, body)
  - `[:method, :uri, :query]` - Match method, path, and query params
  - `[:method, :uri, :query, :body]` - Match method, path, query, and body
  - `[:method, :uri, :query, :headers, :body]` - Match everything (most strict)

  ## Returns

  - `{:ok, response}` - Found a matching interaction, returns the response map
  - `:not_found` - No interaction matches the given criteria

  ## Normalization

  To ensure consistent matching, certain fields are normalized:

  - **Query strings**: `?a=1&b=2` matches `?b=2&a=1`
  - **JSON bodies**: `{"a":1,"b":2}` matches `{"b":2,"a":1}`
  - **Headers**: Case-insensitive comparison, sorted by key

  This allows for flexible matching while maintaining deterministic behavior.

  ## Examples

      # Basic matching on method and URI only
      case find_interaction(cassette, conn, body, [:method, :uri]) do
        {:ok, response} ->
          # Found: use the cached response
          response
        :not_found ->
          # Not found: need to record new interaction
          make_real_request(conn, body)
      end

      # Match on method, URI, and query (useful for GET requests with params)
      find_interaction(cassette, conn, "", [:method, :uri, :query])
      #=> {:ok, %{"status" => 200, "headers" => %{}, ...}}

      # Strict matching (all criteria)
      find_interaction(cassette, conn, body, [:method, :uri, :query, :headers, :body])
      #=> :not_found

      # Ignore request body differences (useful for POST with timestamps)
      conn = %Plug.Conn{method: "POST", request_path: "/api/users", ...}
      body1 = ~s({"name":"Alice","timestamp":"2025-10-16T10:00:00Z"})
      body2 = ~s({"name":"Alice","timestamp":"2025-10-16T10:00:01Z"})

      # First call records with body1
      cassette = add_interaction(cassette, conn, body1, response1)

      # Second call with different body but same method/URI matches!
      find_interaction(cassette, conn, body2, [:method, :uri])
      #=> {:ok, response1}

      # Multiple interactions in cassette - finds first match
      cassette = new()
      |> add_interaction(conn_get, "", resp_get)
      |> add_interaction(conn_post, post_body, resp_post)

      find_interaction(cassette, conn_get, "", [:method, :uri])
      #=> {:ok, resp_get}

      find_interaction(cassette, conn_post, post_body, [:method, :uri, :body])
      #=> {:ok, resp_post}
  """
  @spec find_interaction(map(), map(), [atom()]) :: {:ok, map()} | :not_found
  def find_interaction(cassette, filtered_request, match_on) do
    interactions = Map.get(cassette, "interactions", [])

    Enum.find_value(interactions, :not_found, fn interaction ->
      cond do
        # Use template matching if interaction has templates enabled
        interaction["template"] && interaction["template"]["enabled"] ->
          case try_template_match(interaction, filtered_request) do
            {:ok, response} -> {:ok, response}
            # Continue searching
            :no_match -> nil
          end

        # No templates, use standard exact matching
        true ->
          if interaction_matches?(interaction, filtered_request, match_on) do
            {:ok, interaction["response"]}
          end
      end
    end)
  end

  @doc """
  Diagnoses why a request didn't match any interaction in the cassette.

  Returns detailed diagnostic information for each interaction showing which
  matchers matched and which didn't, along with the stored and incoming values.

  ## Parameters

  - `cassette` - The cassette map
  - `conn` - The `Plug.Conn` struct representing the current request
  - `request_body` - The raw request body as a binary string
  - `match_on` - List of matchers to check
  - `filter_opts` - Optional filter options (default: `%{}`)

  ## Returns

  A list of diagnostic maps, one per interaction:

      [
        %{
          index: 0,
          results: %{
            method: {:match, "POST", "POST"},
            uri: {:no_match, "https://stored.url", "https://incoming.url"},
            ...
          }
        },
        ...
      ]

  ## Examples

      diagnostics = diagnose_mismatch(cassette, conn, body, [:method, :uri])
      formatted = format_mismatch_diagnostics(diagnostics, [:method, :uri])
  """
  @spec diagnose_mismatch(map(), Plug.Conn.t(), binary(), [atom()], map()) :: list(map())
  def diagnose_mismatch(cassette, conn, request_body, match_on, filter_opts \\ %{}) do
    interactions = Map.get(cassette, "interactions", [])
    incoming_request = build_incoming_request(conn, request_body, filter_opts)

    interactions
    |> Enum.with_index()
    |> Enum.map(fn {interaction, index} ->
      results = diagnose_interaction(interaction, incoming_request, match_on, filter_opts, conn)
      %{index: index, results: results}
    end)
  end

  @doc """
  Formats diagnostic results into a human-readable string.

  ## Parameters

  - `diagnostics` - List of diagnostic maps from `diagnose_mismatch/5`
  - `match_on` - List of matchers being checked

  ## Returns

  A formatted string showing match status and details for mismatches.

  ## Examples

      diagnostics = diagnose_mismatch(cassette, conn, body, [:method, :uri])
      IO.puts(format_mismatch_diagnostics(diagnostics, [:method, :uri]))

      # Output:
      # 🟢 :method match
      # 🔴 :uri NO match
      #
      # 🔬 :uri details
      #
      # Record 1:
      # stored: "https://api.example.com/old"
      # value:  "https://api.example.com/new"
  """
  @spec format_mismatch_diagnostics(list(map()), [atom()]) :: String.t()
  def format_mismatch_diagnostics(diagnostics, match_on) do
    # Calculate overall match status across all interactions
    overall_status = calculate_overall_match_status(diagnostics, match_on)

    # Build summary section
    summary =
      match_on
      |> Enum.map(fn matcher ->
        case Map.get(overall_status, matcher) do
          :match -> "🟢 :#{matcher} match"
          :no_match -> "🔴 :#{matcher} NO match"
          _ -> "⚪ :#{matcher} unknown"
        end
      end)
      |> Enum.join("\n")

    # Build details section for mismatched fields
    mismatched_fields =
      overall_status
      |> Enum.filter(fn {_field, status} -> status == :no_match end)
      |> Enum.map(fn {field, _} -> field end)

    details =
      mismatched_fields
      |> Enum.map(fn field ->
        field_details = format_field_details(diagnostics, field)
        "\n🔬 :#{field} details\n#{field_details}"
      end)
      |> Enum.join("\n")

    summary <> details
  end

  @doc """
  Saves a cassette to disk as pretty-printed JSON in v2.0 format.

  Always saves as v2.0 format with sorted JSON for consistency and git-friendliness.

  ## Parameters

  - `path` - File path where cassette should be saved
  - `cassette` - The cassette map

  ## Examples

      save("/path/to/cassette.json", cassette)
  """
  @spec save(String.t(), map()) :: :ok
  def save(path, cassette) do
    # Ensure we're saving as v2.0
    cassette_v2 = Map.put(cassette, "version", @version)

    # Normalize all interactions (sort JSON) before saving
    normalized_interactions =
      Enum.map(cassette_v2["interactions"] || [], &normalize_interaction_for_save/1)

    cassette_final = Map.put(cassette_v2, "interactions", normalized_interactions)

    File.mkdir_p!(Path.dirname(path))
    json = Jason.encode!(cassette_final, pretty: true)
    File.write!(path, json)
  end

  @doc """
  Loads a cassette from disk.

  Supports v2.0 (with templates), v1.0, and v0.1 formats for backward compatibility.

  ## Version Handling

  - **v2.0** - Latest format with template support and sorted JSON (loaded as-is)
  - **v1.0** - Previous format, normalized to v2.0 in memory (JSON sorted on load)
  - **v0.1** - Legacy format, migrated to v2.0

  ## Parameters

  - `path` - File path to load cassette from

  ## Returns

  - `{:ok, cassette}` - Successfully loaded cassette (normalized to v2.0 if needed)
  - `:not_found` - File doesn't exist or can't be parsed

  ## Examples

      load("/path/to/cassette.json")
      # => {:ok, %{"version" => "2.0", "interactions" => [...]}}

      load("/path/to/missing.json")
      # => :not_found
  """
  @spec load(String.t()) :: {:ok, map()} | :not_found
  def load(path) do
    if File.exists?(path) do
      with {:ok, data} <- File.read(path),
           {:ok, parsed} <- Jason.decode(data) do
        cassette = migrate_if_needed(parsed)
        {:ok, cassette}
      else
        _ -> :not_found
      end
    else
      :not_found
    end
  end

  # Private helpers

  # Diagnostic helpers

  defp diagnose_interaction(interaction, incoming_request, match_on, filter_opts, conn) do
    request = interaction["request"]

    match_on
    |> Enum.map(fn matcher ->
      {status, stored, incoming} =
        diagnose_matcher(matcher, request, incoming_request, filter_opts, conn)

      {matcher, {status, stored, incoming}}
    end)
    |> Enum.into(%{})
  end

  defp diagnose_matcher(:method, request, incoming_request, _filter_opts, _conn) do
    stored = request["method"]
    incoming = incoming_request["method"]
    matches = String.upcase(stored) == String.upcase(incoming)
    {if(matches, do: :match, else: :no_match), stored, incoming}
  end

  defp diagnose_matcher(:uri, request, incoming_request, filter_opts, _conn) do
    stored = request["uri"]

    incoming =
      apply_regex_filters_to_string(
        incoming_request["uri"],
        filter_opts[:filter_sensitive_data] || []
      )

    matches = incoming == stored
    {if(matches, do: :match, else: :no_match), stored, incoming}
  end

  defp diagnose_matcher(:query, request, incoming_request, filter_opts, _conn) do
    stored = request["query_string"]

    incoming =
      apply_regex_filters_to_string(
        incoming_request["query_string"],
        filter_opts[:filter_sensitive_data] || []
      )

    matches = normalize_query(stored) == normalize_query(incoming)
    {if(matches, do: :match, else: :no_match), stored, incoming}
  end

  defp diagnose_matcher(:headers, request, incoming_request, filter_opts, _conn) do
    stored = request["headers"]

    incoming =
      apply_header_filters(
        incoming_request["headers"],
        filter_opts[:filter_request_headers] || []
      )

    matches = normalize_headers(stored) == normalize_headers(incoming)
    {if(matches, do: :match, else: :no_match), stored, incoming}
  end

  defp diagnose_matcher(:body, request, incoming_request, filter_opts, conn) do
    stored = reconstruct_request_body(request)
    incoming_raw = reconstruct_request_body(incoming_request)

    incoming =
      apply_regex_filters_to_string(
        incoming_raw,
        filter_opts[:filter_sensitive_data] || []
      )

    matches = bodies_match?(request, incoming, conn.req_headers)
    {if(matches, do: :match, else: :no_match), stored, incoming}
  end

  defp diagnose_matcher(_matcher, _request, _incoming_request, _filter_opts, _conn) do
    {:match, nil, nil}
  end

  defp calculate_overall_match_status(diagnostics, match_on) do
    # For each matcher, if ANY interaction matched on that field, mark as :match
    # Otherwise :no_match
    match_on
    |> Enum.map(fn matcher ->
      any_matched =
        Enum.any?(diagnostics, fn %{results: results} ->
          case Map.get(results, matcher) do
            {:match, _, _} -> true
            _ -> false
          end
        end)

      {matcher, if(any_matched, do: :match, else: :no_match)}
    end)
    |> Enum.into(%{})
  end

  defp format_field_details(diagnostics, field) do
    diagnostics
    |> Enum.map(fn %{index: index, results: results} ->
      case Map.get(results, field) do
        {_status, stored, incoming} ->
          """

          Record #{index + 1}:
          stored: #{format_value(stored)}
          value:  #{format_value(incoming)}
          """

        _ ->
          ""
      end
    end)
    |> Enum.join("")
  end

  defp format_value(nil), do: "nil"
  defp format_value(value) when is_binary(value), do: truncate_value(inspect(value))
  defp format_value(value) when is_map(value), do: truncate_value(inspect(value))
  defp format_value(value), do: truncate_value(inspect(value))

  @max_value_length 200
  defp truncate_value(str) when byte_size(str) > @max_value_length do
    String.slice(str, 0, @max_value_length) <> "..."
  end

  defp truncate_value(str), do: str

  defp build_incoming_request(conn, request_body, filter_opts) do
    # Detect body type and encode it the same way as build_interaction does
    body_type = BodyType.detect_type(request_body, headers_to_map(conn.req_headers))
    {body_field, body_value} = BodyType.encode(request_body, body_type)

    incoming =
      %{
        "method" => conn.method,
        "uri" => build_uri(conn),
        "query_string" => conn.query_string,
        "headers" => headers_to_map(conn.req_headers),
        "body_type" => to_string(body_type)
      }
      |> Map.put(body_field, body_value)

    # Apply filter_request callback if present
    case filter_opts[:filter_request] do
      nil -> incoming
      callback when is_function(callback, 1) -> callback.(incoming)
      _ -> incoming
    end
  end

  defp apply_regex_filters_to_string(string, []), do: string

  defp apply_regex_filters_to_string(string, patterns) do
    Enum.reduce(patterns, string, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  defp apply_header_filters(headers, []), do: headers

  defp apply_header_filters(headers, filter_list) do
    # Handle both list and map formats
    headers_map =
      if is_list(headers) do
        headers_to_map(headers)
      else
        headers
      end

    filter_list_normalized = Enum.map(filter_list, &String.downcase/1)

    filtered_map =
      Enum.reject(headers_map, fn {key, _value} ->
        String.downcase(key) in filter_list_normalized
      end)
      |> Enum.into(%{})

    # Return in same format as input
    if is_list(headers) do
      Map.to_list(filtered_map)
    else
      filtered_map
    end
  end

  defp bodies_match?(request, conn_body, conn_headers) do
    stored_body = reconstruct_request_body(request)
    stored_type = BodyType.detect_type(stored_body, request["headers"])
    conn_type = BodyType.detect_type(conn_body, headers_to_map(conn_headers))

    cond do
      stored_type == :json and conn_type == :json ->
        # Normalize JSON for comparison (key order doesn't matter)
        normalize_json(stored_body) == normalize_json(conn_body)

      true ->
        # String comparison
        stored_body == conn_body
    end
  end

  defp reconstruct_request_body(request) do
    cond do
      Map.has_key?(request, "body_json") ->
        Jason.encode!(request["body_json"])

      Map.has_key?(request, "body_blob") ->
        Base.decode64!(request["body_blob"])

      Map.has_key?(request, "body") ->
        request["body"]

      true ->
        ""
    end
  end

  defp build_interaction(conn, request_body, response) do
    req_body_type = BodyType.detect_type(request_body, conn.req_headers |> headers_to_map())
    {req_body_field, req_body_value} = BodyType.encode(request_body, req_body_type)

    resp_body_type = BodyType.detect_type(response.body, response.headers)
    {resp_body_field, resp_body_value} = BodyType.encode(response.body, resp_body_type)

    %{
      "request" => %{
        "method" => conn.method,
        "uri" => build_uri(conn),
        "query_string" => conn.query_string,
        "headers" => conn.req_headers |> headers_to_map(),
        "body_type" => to_string(req_body_type),
        req_body_field => req_body_value
      },
      "response" => %{
        "status" => response.status,
        "headers" => response.headers,
        "body_type" => to_string(resp_body_type),
        resp_body_field => resp_body_value
      },
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Build interaction from already-filtered request
  defp build_interaction_from_filtered(filtered_request, response) do
    resp_body_type = BodyType.detect_type(response.body, response.headers)
    {resp_body_field, resp_body_value} = BodyType.encode(response.body, resp_body_type)

    %{
      "request" => filtered_request,
      "response" => %{
        "status" => response.status,
        "headers" => response.headers,
        "body_type" => to_string(resp_body_type),
        resp_body_field => resp_body_value
      },
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp headers_to_map(headers) when is_list(headers) do
    Enum.into(headers, %{}, fn
      {k, v} when is_list(v) -> {k, v}
      {k, v} -> {k, [v]}
    end)
  end

  defp interaction_matches?(interaction_or_request, filtered_request, match_on) do
    # Handle both full interaction objects and standalone request objects
    request =
      if Map.has_key?(interaction_or_request, "request") do
        interaction_or_request["request"]
      else
        interaction_or_request
      end

    # filtered_request is already filtered, so just compare directly
    Enum.all?(match_on, fn matcher ->
      case matcher do
        :method ->
          String.upcase(request["method"]) == String.upcase(filtered_request["method"])

        :uri ->
          request["uri"] == filtered_request["uri"]

        :query ->
          normalize_query(request["query_string"]) ==
            normalize_query(filtered_request["query_string"])

        :headers ->
          normalize_headers(request["headers"]) == normalize_headers(filtered_request["headers"])

        :body ->
          # For JSON bodies, compare normalized JSON
          # For other bodies, compare as strings
          bodies_match_filtered?(request, filtered_request)

        _ ->
          true
      end
    end)
  end

  # Compare bodies for filtered requests (both are already in request map format)
  defp bodies_match_filtered?(cassette_request, filtered_request) do
    cond do
      Map.has_key?(cassette_request, "body_json") and Map.has_key?(filtered_request, "body_json") ->
        # Both are JSON - normalize and compare
        normalize_json(cassette_request["body_json"]) ==
          normalize_json(filtered_request["body_json"])

      Map.has_key?(cassette_request, "body") and Map.has_key?(filtered_request, "body") ->
        # Both are plain text
        cassette_request["body"] == filtered_request["body"]

      Map.has_key?(cassette_request, "body_blob") and Map.has_key?(filtered_request, "body_blob") ->
        # Both are blobs
        cassette_request["body_blob"] == filtered_request["body_blob"]

      true ->
        # Different body types or both empty - consider not matching
        false
    end
  end

  defp build_uri(conn) do
    scheme = to_string(conn.scheme || if(conn.port == 443, do: "https", else: "http"))
    host = conn.host || "localhost"
    port = conn.port || 80

    # Only include port if non-standard
    port_str =
      cond do
        scheme == "http" and port == 80 -> ""
        scheme == "https" and port == 443 -> ""
        true -> ":#{port}"
      end

    "#{scheme}://#{host}#{port_str}#{conn.request_path}"
  end

  defp normalize_query(""), do: %{}

  defp normalize_query(query_string) do
    query_string
    |> URI.decode_query()
    |> Enum.sort()
    |> Enum.into(%{})
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> headers_to_map()
    |> normalize_headers()
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {k, v} -> {String.downcase(k), normalize_header_value(v)} end)
    |> Enum.sort()
    |> Enum.into(%{})
  end

  defp normalize_header_value(v) when is_list(v), do: Enum.sort(v)
  defp normalize_header_value(v), do: [v]

  defp normalize_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> normalize_json(decoded)
      {:error, _} -> body
    end
  end

  defp normalize_json(body) when is_map(body) do
    body
    |> Enum.sort()
    |> Enum.into(%{}, fn {k, v} -> {k, normalize_json(v)} end)
  end

  defp normalize_json(body) when is_list(body) do
    Enum.map(body, &normalize_json/1)
  end

  defp normalize_json(body), do: body

  # Try to match an incoming request against a templated interaction
  defp try_template_match(interaction, filtered_request) do
    # 1. Normalize incoming request (already filtered)
    normalized_incoming = Normalizer.normalize_request(filtered_request)

    # 2. Deserialize patterns from cassette
    patterns = deserialize_patterns(interaction["template"]["patterns"] || %{})

    # 3. Extract variables from incoming request
    incoming_vars = Extractor.extract_from_request(normalized_incoming, patterns)

    # 4. Create templated version of incoming request
    templated_incoming =
      Replacer.create_template_from_data(normalized_incoming, incoming_vars, scope: :all)

    # 5. Match against cassette's templated request
    cassette_templated = interaction["request"]
    debug_enabled = get_in(interaction, ["template", "config", "debug"]) || false

    result = Matcher.match?(cassette_templated, templated_incoming)

    # Log the match attempt if debug is enabled
    Debug.log_match_attempt(
      cassette_templated,
      templated_incoming,
      result,
      incoming_vars,
      debug_enabled
    )

    case result do
      :match ->
        # 6. Substitute new variables into response template
        templated_response = interaction["response"]
        substituted_response = Replacer.apply_template_to_data(templated_response, incoming_vars)
        {:ok, substituted_response}

      {:error, _diff} ->
        :no_match
    end
  end

  # Deserialize regex patterns from JSON strings
  # Supports both legacy format (source string only) and new format (source + opts)
  defp deserialize_patterns(patterns) when is_map(patterns) do
    Map.new(patterns, fn {name, value} ->
      regex =
        case value do
          # New format: map with source and opts
          %{"source" => source, "opts" => opts} ->
            # Convert string options back to atoms (JSON serializes atoms as strings)
            atom_opts = Enum.map(opts, &String.to_existing_atom/1)
            Regex.compile!(source, atom_opts)

          # Legacy format: just the source string
          source when is_binary(source) ->
            Regex.compile!(source)
        end

      {String.to_atom(name), regex}
    end)
  end

  # Apply template transformation to an interaction
  defp apply_template_to_interaction(interaction, template_opts) do
    # 1. Normalize request and response for predictable extraction
    normalized_request = Normalizer.normalize_request(interaction["request"])
    normalized_response = Normalizer.normalize_response(interaction["response"])

    # 2. Extract variables from request using patterns
    patterns = template_opts[:patterns] || %{}
    debug_enabled = template_opts[:debug] || false
    request_vars = Extractor.extract_from_request(normalized_request, patterns)

    # Log extraction if debug is enabled
    Debug.log_extraction(request_vars, patterns, debug_enabled)

    # 3. Create templated request
    templated_request =
      Replacer.create_template_from_data(normalized_request, request_vars, scope: :all)

    # 4. Scan response to find which request variables appear in it
    response_var_refs = Extractor.scan_response(normalized_response, request_vars)

    # 5. Create templated response (only template vars that appear in both)
    templated_response =
      Replacer.create_template_from_data(normalized_response, request_vars,
        scope: response_var_refs,
        allow_key_templates: template_opts[:allow_key_templates] || false
      )

    # 6. Build interaction with template metadata
    # Deduplicate recorded_values to store only unique values (maintaining order)
    deduplicated_vars =
      Map.new(request_vars, fn {name, values} ->
        {name, Enum.uniq(values)}
      end)

    %{
      "template" => %{
        "enabled" => true,
        "patterns" => serialize_patterns(patterns),
        "recorded_values" => deduplicated_vars,
        "config" => %{
          "allow_key_templates" => template_opts[:allow_key_templates] || false,
          "debug" => debug_enabled
        }
      },
      "request" => templated_request,
      "response" => templated_response,
      "recorded_at" => interaction["recorded_at"]
    }
  end

  # Serialize regex patterns for JSON storage (preserving source and options)
  defp serialize_patterns(patterns) when is_map(patterns) do
    Map.new(patterns, fn {name, regex} ->
      {to_string(name), %{"source" => Regex.source(regex), "opts" => Regex.opts(regex)}}
    end)
  end

  # Migrate cassettes to v2.0 format
  defp migrate_if_needed(%{"version" => "2.0"} = cassette), do: cassette

  defp migrate_if_needed(%{"version" => "1.0"} = cassette) do
    # v1.0 → v2.0: Normalize interactions in memory (sort JSON)
    normalized_interactions =
      Enum.map(cassette["interactions"], &normalize_v1_interaction/1)

    %{cassette | "version" => @version, "interactions" => normalized_interactions}
  end

  defp migrate_if_needed(%{"status" => status, "headers" => headers, "body" => body}) do
    # v0.1 format - single response
    # Convert to v1.0 with one interaction
    # Note: We lose request details in v0.1 migration
    body_type = BodyType.detect_type(body, headers)
    {body_field, body_value} = BodyType.encode(body, body_type)

    %{
      "version" => @version,
      "interactions" => [
        %{
          "request" => %{
            "method" => "UNKNOWN",
            "uri" => "UNKNOWN",
            "query_string" => "",
            "headers" => %{},
            "body_type" => "text",
            "body" => ""
          },
          "response" => %{
            "status" => status,
            "headers" => headers,
            "body_type" => to_string(body_type),
            body_field => body_value
          },
          "recorded_at" => "MIGRATED_FROM_V0.1"
        }
      ]
    }
  end

  defp migrate_if_needed(cassette), do: cassette

  # Normalize a v1.0 interaction to v2.0 (sort JSON bodies)
  defp normalize_v1_interaction(interaction) do
    interaction
    |> normalize_interaction_request()
    |> normalize_interaction_response()
  end

  # Normalize interaction before saving (ensure v2.0 format with sorted JSON)
  defp normalize_interaction_for_save(interaction) do
    interaction
    |> normalize_interaction_request()
    |> normalize_interaction_response()
  end

  defp normalize_interaction_request(interaction) do
    if request = interaction["request"] do
      normalized_request = Normalizer.normalize_request(request)
      Map.put(interaction, "request", normalized_request)
    else
      interaction
    end
  end

  defp normalize_interaction_response(interaction) do
    if response = interaction["response"] do
      normalized_response = Normalizer.normalize_response(response)
      Map.put(interaction, "response", normalized_response)
    else
      interaction
    end
  end
end
