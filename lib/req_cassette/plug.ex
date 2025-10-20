defmodule ReqCassette.Plug do
  @moduledoc """
  A Plug that intercepts Req HTTP requests and records/replays them from cassette files.

  This module implements the `Plug` behaviour and is designed to be used with Req's
  `:plug` option to enable VCR-style testing for HTTP clients.

  ## Usage

  The easiest way to use this plug is via the `ReqCassette.with_cassette/3` function,
  but it can also be used directly with Req:

      # With with_cassette/3 (recommended)
      ReqCassette.with_cassette("my_api_call", [cassette_dir: "test/cassettes"], fn plug ->
        Req.get!("https://api.example.com/data", plug: plug)
      end)

      # Direct usage
      Req.get!(
        "https://api.example.com/data",
        plug: {ReqCassette.Plug, %{
          cassette_name: "my_api_call",
          cassette_dir: "test/cassettes"
        }}
      )

  > #### Cassette Naming Best Practice {: .warning}
  >
  > Always provide `:cassette_name` for human-readable, maintainable cassette files.
  >
  > **Without cassette_name** (not recommended):
  >
  >     plug: {ReqCassette.Plug, %{cassette_dir: "test/cassettes"}}
  >     # Creates: a1b2c3d4e5f6789012345678901234ab.json
  >     # ❌ Cryptic MD5 hash - hard to identify which test this belongs to
  >
  > **With cassette_name** (recommended):
  >
  >     plug: {ReqCassette.Plug, %{cassette_name: "github_user", cassette_dir: "test/cassettes"}}
  >     # Creates: github_user.json
  >     # ✅ Clear, readable - easy to manage and understand
  >
  > The MD5 hash fallback exists for backward compatibility but should be avoided in new code.

  ## Options

  - `:cassette_name` - **(Recommended)** Human-readable name for the cassette file (e.g., `"github_api"`).
    Creates `github_api.json`. If omitted, generates a cryptic MD5 hash filename based on
    matching options (`:mode`, `:cassette_dir`, and `:cassette_name` are excluded from hash).
    **Always provide this option for maintainable tests.**
  - `:cassette_dir` - Directory where cassette files are stored (default: `"cassettes"`)
  - `:mode` - Recording mode (default: `:record`). See "Recording Modes" below.
  - `:match_requests_on` - List of criteria for matching requests (default: `[:method, :uri, :query, :headers, :body]`)
  - `:filter_sensitive_data` - List of `{regex, replacement}` tuples to filter sensitive data
  - `:filter_request_headers` - List of request header names to remove (case-insensitive)
  - `:filter_response_headers` - List of response header names to remove (case-insensitive)
  - `:before_record` - Callback function for custom filtering (receives and returns interaction map)

  ## Recording Modes

  ReqCassette supports three recording modes that control when cassettes are created/used:

  ### `:record` (default)

  Records new interactions, replays existing ones. Appends to existing cassettes.
  Ideal for development:

      # First run: records interaction to cassette
      ReqCassette.with_cassette("api", [], fn plug ->
        Req.get!("https://api.example.com/data", plug: plug)
      end)

      # Subsequent runs: replays from cassette (no network call)

      # To re-record: delete cassette file first
      File.rm!("test/cassettes/api.json")

  ### `:replay`

  Only replays from cassettes. Raises error if cassette or matching interaction not found.
  Perfect for CI environments to ensure no unexpected network calls:

      ReqCassette.with_cassette("api", [mode: :replay], fn plug ->
        Req.get!("https://api.example.com/data", plug: plug)
        # Raises if cassette doesn't exist or no matching interaction
      end)

  ### `:bypass`

  Ignores cassettes completely, always hits the network. Never saves. Useful for
  debugging or selectively disabling cassettes:

      ReqCassette.with_cassette("api", [mode: :bypass], fn plug ->
        Req.get!("https://api.example.com/data", plug: plug)
        # Always hits network, never creates cassette
      end)

  ## Request Matching

  By default, requests are matched on all criteria (method, URI, query, headers, body).
  You can customize this with `:match_requests_on`:

      # Only match on method and URI (ignore query params and body)
      ReqCassette.with_cassette(
        "search",
        [match_requests_on: [:method, :uri]],
        fn plug ->
          Req.get!("https://api.example.com/search?q=foo", plug: plug)
          # Later: ?q=bar will replay the same response
        end
      )

  Available matchers:
  - `:method` - HTTP method (GET, POST, etc.)
  - `:uri` - Path without query string
  - `:query` - Query parameters (order-independent)
  - `:headers` - Request headers (case-insensitive)
  - `:body` - Request body (JSON key order-independent)

  ## Cassette File Format

  Cassettes use v1.0 format with pretty-printed JSON and multiple interactions:

      {
        "version": "1.0",
        "interactions": [
          {
            "request": {
              "method": "GET",
              "uri": "/api/users/1",
              "query_string": "",
              "headers": {
                "accept": ["application/json"]
              },
              "body": ""
            },
            "response": {
              "status": 200,
              "headers": {
                "content-type": ["application/json"]
              },
              "body_json": {
                "id": 1,
                "name": "Alice"
              }
            },
            "recorded_at": "2025-10-16T12:00:00Z"
          }
        ]
      }

  ### Body Types

  Responses are stored in one of three formats based on content type:

  - `body_json` - JSON responses stored as native objects (pretty-printed)
  - `body` - Text responses (HTML, XML, CSV) stored as strings
  - `body_blob` - Binary data (images, PDFs) stored as base64

  This approach produces compact, human-readable cassette files.

  ## Examples

      # Basic GET request with human-readable filename
      ReqCassette.with_cassette("github_user", [], fn plug ->
        Req.get!("https://api.github.com/users/octocat", plug: plug)
      end)
      # Creates: test/cassettes/github_user.json

      # POST with custom matching (ignore request body)
      ReqCassette.with_cassette(
        "create_user",
        [match_requests_on: [:method, :uri]],
        fn plug ->
          Req.post!(
            "https://api.example.com/users",
            json: %{name: "Alice"},
            plug: plug
          )
        end
      )

      # Filter sensitive data with regex
      ReqCassette.with_cassette(
        "authenticated",
        [
          filter_sensitive_data: [
            {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"}
          ],
          filter_request_headers: ["authorization"]
        ],
        fn plug ->
          Req.get!(
            "https://api.example.com/data?api_key=secret",
            headers: [{"authorization", "Bearer token"}],
            plug: plug
          )
        end
      )

      # Multiple requests in one cassette
      ReqCassette.with_cassette("workflow", [], fn plug ->
        user = Req.get!("https://api.example.com/user", plug: plug)
        posts = Req.get!("https://api.example.com/posts", plug: plug)
        {user, posts}
      end)
      # Single cassette file contains both interactions

      # Custom filtering with callback
      ReqCassette.with_cassette(
        "custom_filter",
        [
          before_record: fn interaction ->
            put_in(interaction, ["response", "body_json", "email"], "redacted@example.com")
          end
        ],
        fn plug ->
          Req.get!("https://api.example.com/profile", plug: plug)
        end
      )

  ## Architecture

  This plug uses Req's native plug system, which provides:

  - ✅ **Async-safe**: Works with `async: true` in ExUnit
  - ✅ **Process-isolated**: No global state or process dictionary
  - ✅ **Adapter-agnostic**: Works with any Req adapter (Finch, etc.)
  - ✅ **No mocking**: Uses stable, public APIs

  ## How It Works

  1. **Recording Flow** (`:record` mode):
     - Intercepts the outgoing Req request via the plug callback
     - Checks if a matching cassette/interaction exists
     - If not found, forwards the request to the real server
     - Applies filters to remove sensitive data
     - Saves the response to a cassette file (pretty-printed JSON)
     - Returns the response to the caller

  2. **Replay Flow** (`:replay` or `:record` with existing cassette):
     - Intercepts the outgoing request
     - Finds the matching cassette file by name
     - Searches for a matching interaction using configured matchers
     - Loads and returns the saved response
     - No network call is made

  3. **Bypass Flow** (`:bypass` mode):
     - Forwards request directly to the network
     - Never reads or writes cassettes
     - Useful for debugging or selectively disabling recording

  ## Integration with ReqLLM

  Works seamlessly with ReqLLM for testing LLM integrations:

      ReqCassette.with_cassette("claude_chat", [], fn plug ->
        ReqLLM.chat(
          "anthropic:claude-sonnet-4-20250514",
          [%{role: "user", content: "Hello!"}],
          req_http_options: [plug: plug]
        )
      end)
  """
  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn
  alias Req.Steps
  alias ReqCassette.BodyType
  alias ReqCassette.Cassette

  @typedoc """
  Options for configuring the cassette plug.

  - `:cassette_dir` - Directory where cassette files are stored
  - `:cassette_name` - Human-readable name for the cassette file
  - `:mode` - Recording mode (`:replay`, `:record`, `:bypass`)
  - `:match_requests_on` - List of matchers for finding interactions
  """
  @type opts :: %{
          optional(:cassette_name) => String.t(),
          cassette_dir: String.t(),
          mode: :replay | :record | :bypass,
          match_requests_on: [atom()]
        }

  @default_opts %{
    cassette_dir: "cassettes",
    mode: :record,
    match_requests_on: [:method, :uri, :query, :headers, :body]
  }

  @doc """
  Initializes the plug with the given options.

  This callback is invoked by Req when the plug is first used. It merges the provided
  options with default values to create the final configuration.

  ## Parameters

  - `opts` - A map of options (see `t:opts/0`)

  ## Returns

  The merged options map with defaults applied.

  ## Default Options

  - `cassette_dir: "cassettes"` - Directory for storing cassette files
  - `mode: :record` - Record new interactions, replay existing ones
  - `match_requests_on: [:method, :uri, :query, :headers, :body]` - Match on all criteria

  ## Examples

      # Minimal options (uses defaults)
      opts = %{cassette_name: "my_api"}
      ReqCassette.Plug.init(opts)
      #=> %{
      #     cassette_name: "my_api",
      #     cassette_dir: "cassettes",
      #     mode: :record,
      #     match_requests_on: [:method, :uri, :query, :headers, :body]
      #   }

      # Custom options override defaults
      opts = %{
        cassette_name: "my_api",
        mode: :replay,
        match_requests_on: [:method, :uri]
      }
      ReqCassette.Plug.init(opts)
      #=> %{
      #     cassette_name: "my_api",
      #     cassette_dir: "cassettes",
      #     mode: :replay,
      #     match_requests_on: [:method, :uri]
      #   }
  """
  @spec init(opts() | map()) :: opts()
  def init(opts) do
    Map.merge(@default_opts, opts)
  end

  @doc """
  Handles an incoming HTTP request by either replaying from cassette or recording.

  This is the main entry point for the plug, called by Req for each HTTP request.
  The behavior depends on the configured mode:

  - **`:record`** (default) - Checks for matching interaction, records if not found
  - **`:replay`** - Only uses cassettes, raises error if not found
  - **`:bypass`** - Ignores cassettes, always uses network

  ## Parameters

  - `conn` - The `Plug.Conn` struct representing the incoming request
  - `opts` - The plug options (see `t:opts/0`)

  ## Returns

  A `Plug.Conn` struct with the response set and halted.

  ## Request Matching

  When looking for a matching interaction in an existing cassette, the plug uses
  the matchers specified in `:match_requests_on`. For example:

  - `[:method, :uri]` - Match only method and path (ignore query params and body)
  - `[:method, :uri, :query]` - Match method, path, and query params
  - `[:method, :uri, :query, :headers, :body]` - Match everything (default)

  Query parameters and JSON body keys are normalized (order-independent) to ensure
  consistent matching.

  ## Filtering

  Before recording, the plug applies filters in this order:

  1. **Regex filters** (`:filter_sensitive_data`) - Applied to URI, query string, and bodies
  2. **Header filters** (`:filter_request_headers`, `:filter_response_headers`) - Removes specified headers
  3. **Callback filter** (`:before_record`) - Custom transformation function

  ## Examples

      # Direct plug usage with replay mode (CI environment)
      plug_opts = %{
        cassette_name: "github_api",
        cassette_dir: "test/cassettes",
        mode: :replay
      }

      conn = %Plug.Conn{
        method: "GET",
        request_path: "/users/octocat",
        # ... other fields
      }

      # Raises if cassette doesn't exist
      conn = ReqCassette.Plug.call(conn, plug_opts)

      # With custom matching (ignore body differences)
      plug_opts = %{
        cassette_name: "api_call",
        match_requests_on: [:method, :uri, :query]
      }

      conn = ReqCassette.Plug.call(conn, plug_opts)
      # POST requests with different bodies will match the same interaction

      # With filtering
      plug_opts = %{
        cassette_name: "auth_api",
        filter_sensitive_data: [
          {~r/api_key=[\\w-]+/, "api_key=<REDACTED>"}
        ],
        filter_request_headers: ["authorization"]
      }

      conn = ReqCassette.Plug.call(conn, plug_opts)
      # API keys in query string are redacted, authorization headers removed

  ## Errors

  This function raises in the following cases:

  - **Mode `:replay`** with missing cassette
  - **Mode `:replay`** with no matching interaction
  - **Mode `:record`** when network request fails

  The error messages include context to help debug the issue.
  """
  @spec call(Conn.t(), opts()) :: Conn.t()
  def call(conn, opts) do
    # Read the body first so we can include it in the cassette key
    conn = Conn.fetch_query_params(conn)
    {:ok, body, conn} = Conn.read_body(conn)

    # Handle different recording modes
    case opts.mode do
      :bypass ->
        # Bypass mode - ignore cassettes, always hit network
        {conn, resp_or_error} = forward_and_capture(conn, body, opts)
        resp = normalize_response(resp_or_error)
        resp_to_conn(conn, resp)

      :replay ->
        # Replay mode - only use cassettes, error if missing
        handle_replay(conn, body, opts)

      :record ->
        # Record mode - use cassette if exists, otherwise record (append interactions)
        handle_record(conn, body, opts)
    end
  end

  # Mode handlers

  defp handle_replay(conn, body, opts) do
    path = cassette_path(opts)

    case Cassette.load(path) do
      {:ok, cassette} ->
        match_on = opts[:match_requests_on] || [:method, :uri, :query, :headers, :body]
        filter_opts = extract_filter_opts(opts)

        # Build and filter request ONCE at entry point
        filtered_request = build_and_filter_incoming_request(conn, body, filter_opts)

        case Cassette.find_interaction(cassette, filtered_request, match_on) do
          {:ok, response} ->
            conn
            |> put_resp_headers(response["headers"])
            |> send_resp(response["status"], BodyType.decode(response))
            |> Conn.halt()

          :not_found ->
            diagnostics = Cassette.diagnose_mismatch(cassette, conn, body, match_on, filter_opts)
            diagnostics_str = Cassette.format_mismatch_diagnostics(diagnostics, match_on)

            raise """
            ReqCassette: No matching interaction found in cassette #{path}

            Request: #{conn.method} #{conn.request_path}
            Matching on: #{inspect(match_on)}

            This cassette exists but doesn't contain a matching interaction.
            Either add the interaction to the cassette or use mode: :record.

            #{diagnostics_str}
            """
        end

      :not_found ->
        raise """
        ReqCassette: Cassette not found: #{path}

        Mode is :replay which requires an existing cassette.
        Either create the cassette or use mode: :record.
        """
    end
  end

  defp handle_record(conn, body, opts) do
    path = cassette_path(opts)

    case Cassette.load(path) do
      {:ok, cassette} ->
        # Cassette exists - try to find matching interaction
        match_on = opts[:match_requests_on] || [:method, :uri, :query, :headers, :body]
        filter_opts = extract_filter_opts(opts)

        # Build and filter request ONCE at entry point
        filtered_request = build_and_filter_incoming_request(conn, body, filter_opts)

        case Cassette.find_interaction(cassette, filtered_request, match_on) do
          {:ok, response} ->
            # Found matching interaction - replay it
            conn
            |> put_resp_headers(response["headers"])
            |> send_resp(response["status"], BodyType.decode(response))
            |> Conn.halt()

          :not_found ->
            # No matching interaction - record new one
            {conn, resp_or_error} = forward_and_capture(conn, body, opts)
            resp = normalize_response(resp_or_error)

            # Add new interaction using already-filtered request
            cassette = Cassette.add_interaction(cassette, filtered_request, resp, opts)
            Cassette.save(path, cassette)

            resp_to_conn(conn, resp)
        end

      :not_found ->
        # Cassette doesn't exist - record new one
        filter_opts = extract_filter_opts(opts)
        filtered_request = build_and_filter_incoming_request(conn, body, filter_opts)

        {conn, resp_or_error} = forward_and_capture(conn, body, opts)
        resp = normalize_response(resp_or_error)

        cassette = Cassette.new()
        cassette = Cassette.add_interaction(cassette, filtered_request, resp, opts)
        Cassette.save(path, cassette)

        resp_to_conn(conn, resp)
    end
  end

  defp extract_filter_opts(opts) do
    base_opts = %{
      filter_sensitive_data: opts[:filter_sensitive_data] || [],
      filter_request_headers: opts[:filter_request_headers] || [],
      filter_response_headers: opts[:filter_response_headers] || [],
      filter_request: opts[:filter_request],
      filter_response: opts[:filter_response]
    }

    # Add template options if present
    if opts[:template] do
      Map.put(base_opts, :template, opts[:template])
    else
      base_opts
    end
  end

  # Build and filter incoming request once at entry point
  # This ensures all downstream code (template matching, standard matching) works on filtered data
  defp build_and_filter_incoming_request(conn, body, filter_opts) do
    # 1. Build request structure
    body_type = BodyType.detect_type(body, headers_to_map(conn.req_headers))
    {body_field, body_value} = BodyType.encode(body, body_type)

    request =
      %{
        "method" => conn.method,
        "uri" => build_uri(conn),
        "query_string" => conn.query_string,
        "headers" => headers_to_map(conn.req_headers),
        "body_type" => to_string(body_type)
      }
      |> Map.put(body_field, body_value)

    # 2. Apply ALL filters in order: callback → regex → header removal
    request
    |> apply_filter_request_callback(filter_opts[:filter_request])
    |> apply_regex_filters_to_request(filter_opts[:filter_sensitive_data] || [])
    |> apply_request_header_filters(filter_opts[:filter_request_headers] || [])
  end

  # Apply filter_request callback
  defp apply_filter_request_callback(request, nil), do: request

  defp apply_filter_request_callback(request, callback) when is_function(callback, 1) do
    callback.(request)
  end

  defp apply_filter_request_callback(request, _), do: request

  # Apply regex filters to request body and URI/query
  defp apply_regex_filters_to_request(request, []), do: request

  defp apply_regex_filters_to_request(request, filter_patterns) do
    request
    |> apply_regex_to_body(filter_patterns)
    |> apply_regex_to_uri(filter_patterns)
    |> apply_regex_to_query(filter_patterns)
  end

  defp apply_regex_to_body(request, filter_patterns) do
    cond do
      Map.has_key?(request, "body_json") ->
        # Filter JSON by serializing, filtering, deserializing
        json_str = Jason.encode!(request["body_json"])
        filtered_str = apply_regex_to_string(json_str, filter_patterns)

        # Use tolerant decoding - if regex produces invalid JSON, fall back to original
        # This matches the behavior in ReqCassette.Filter.apply_regex_to_body/3
        filtered_json =
          case Jason.decode(filtered_str) do
            {:ok, decoded} -> decoded
            {:error, _} -> request["body_json"]
          end

        Map.put(request, "body_json", filtered_json)

      Map.has_key?(request, "body") ->
        # Filter plain text body
        filtered_body = apply_regex_to_string(request["body"], filter_patterns)
        Map.put(request, "body", filtered_body)

      Map.has_key?(request, "body_blob") ->
        # Filter blob (decode, filter, re-encode)
        blob = Base.decode64!(request["body_blob"])
        filtered = apply_regex_to_string(blob, filter_patterns)
        Map.put(request, "body_blob", Base.encode64(filtered))

      true ->
        request
    end
  end

  defp apply_regex_to_uri(request, filter_patterns) do
    filtered_uri = apply_regex_to_string(request["uri"], filter_patterns)
    Map.put(request, "uri", filtered_uri)
  end

  defp apply_regex_to_query(request, filter_patterns) do
    filtered_query = apply_regex_to_string(request["query_string"], filter_patterns)
    Map.put(request, "query_string", filtered_query)
  end

  defp apply_regex_to_string(string, filter_patterns) do
    Enum.reduce(filter_patterns, string, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  # Apply header filters (remove specified headers)
  defp apply_request_header_filters(request, []), do: request

  defp apply_request_header_filters(request, filter_list) do
    filtered_headers =
      request["headers"]
      |> Enum.reject(fn {key, _value} ->
        Enum.any?(filter_list, &(String.downcase(key) == String.downcase(&1)))
      end)
      |> Enum.into(%{})

    Map.put(request, "headers", filtered_headers)
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

  defp headers_to_map(headers) when is_list(headers) do
    Enum.into(headers, %{}, fn
      {k, v} when is_list(v) -> {k, v}
      {k, v} -> {k, [v]}
    end)
  end

  defp headers_to_map(headers) when is_map(headers), do: headers

  defp cassette_path(opts) do
    dir = opts.cassette_dir || opts[:cassette_dir] || "cassettes"

    filename =
      case opts[:cassette_name] do
        nil ->
          # Generate MD5 hash (backward compatibility)
          # Exclude cassette management options from hash - only hash options that affect matching
          opts_for_hash = Map.drop(opts, [:mode, :cassette_dir, :cassette_name])
          hash = :crypto.hash(:md5, :erlang.term_to_binary(opts_for_hash))
          Base.encode16(hash, case: :lower) <> ".json"

        name ->
          # Use human-readable name
          sanitize_filename(name) <> ".json"
      end

    Path.join(dir, filename)
  end

  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^\w\s\-]/, "_")
    |> String.replace(~r/\s+/, "_")
  end

  defp normalize_response(resp_or_error) do
    case resp_or_error do
      {:ok, %Req.Response{} = r} ->
        r

      %Req.Response{} = r ->
        r

      {:error, error} ->
        raise """
        ReqCassette: Network request failed

        Error: #{inspect(error)}

        This error occurred while trying to record a cassette. Make sure the server is running
        or use mode: :replay to use existing cassettes without hitting the network.
        """

      other ->
        raise "unexpected response format: #{inspect(other)}"
    end
  end

  defp forward_and_capture(conn, body, _opts) do
    # Convert Plug.Conn to a Req request and run it
    method = conn.method |> String.downcase() |> String.to_atom()
    headers = conn.req_headers

    # Build a full URL from conn
    # Use conn.scheme if available, otherwise infer from port
    scheme = to_string(conn.scheme || if(conn.port == 443, do: "https", else: "http"))
    host = conn.host || "localhost"
    port = conn.port || 80

    full =
      URI.to_string(%URI{
        scheme: scheme,
        host: host,
        port: port,
        path: conn.request_path,
        query: conn.query_string
      })

    # Create request options
    req_opts = [method: method, url: full, headers: headers]

    # Add body if present
    req_opts =
      if body != "" do
        req_opts ++ [body: body]
      else
        req_opts
      end

    # Create a new Req without the plug option to avoid infinite recursion
    req = Req.new(adapter: &Steps.run_finch/1)

    resp = Req.request(req, req_opts)
    {conn, resp}
  end

  defp resp_to_conn(conn, %{status: status, headers: headers, body: body}) do
    conn
    |> put_resp_headers(headers)
    |> send_resp(status, serialize_body(body))
    |> Conn.halt()
  end

  defp serialize_body(body) when is_binary(body), do: body

  defp serialize_body(body) do
    # for map/struct/list — convert to JSON
    Jason.encode!(body)
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v_list}, acc ->
      # ensure header name and value are binaries
      value =
        case v_list do
          [v] when is_binary(v) ->
            v

          vs when is_list(vs) ->
            vs
            |> Enum.filter(&is_binary/1)
            |> Enum.join(", ")

          v when is_binary(v) ->
            v

          other ->
            # fallback: convert to string
            to_string(other)
        end

      Conn.put_resp_header(acc, k, value)
    end)
  end
end
