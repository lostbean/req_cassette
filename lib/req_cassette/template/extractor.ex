defmodule ReqCassette.Template.Extractor do
  @moduledoc """
  Extracts template variables from requests and responses using regex patterns.

  This module scans specific parts of HTTP messages (URI, query params, body) to find
  values matching the configured patterns, returning them in a consistent order for
  positional template markers like `{{var.0}}`, `{{var.1}}`.

  ## Extraction Scope

  Patterns are applied to:

  1. **URI Path** - The path component of the URL
  2. **Query Parameters** - URL query string parameters (sorted)
  3. **Request/Response Bodies** - The body content (text, JSON, or blob)

  **NOT scanned:**
  - Headers (to prevent accidental exposure of auth tokens)
  - HTTP Method
  - Status Code

  ## Extraction Order

  Values are extracted in this specific order to ensure predictable positional indexing:

  1. URI path (left to right)
  2. Query parameters (alphabetically sorted by key)
  3. Request/response body (for JSON: depth-first traversal)

  This ensures `{{order_id.0}}`, `{{order_id.1}}`, etc. map consistently.

  ## Examples

      # Basic extraction from request body
      iex> patterns = %{sku: ~r/\\d{4}-\\d{4}/}
      iex> request = %{
      ...>   "uri" => "https://api.example.com/products",
      ...>   "query_string" => "",
      ...>   "body" => "Get SKU 0234-3455 and SKU 0344-4456"
      ...> }
      iex> extract_from_request(request, patterns)
      %{sku: ["0234-3455", "0344-4456"]}

      # Extraction from multiple scopes
      iex> patterns = %{order_id: ~r/ORD-\\d+/}
      iex> request = %{
      ...>   "uri" => "https://api.example.com/orders/ORD-11111",
      ...>   "query_string" => "ref=ORD-22222",
      ...>   "body_json" => %{"related" => "ORD-33333"}
      ...> }
      iex> extract_from_request(request, patterns)
      %{order_id: ["ORD-11111", "ORD-22222", "ORD-33333"]}

      # Multiple patterns
      iex> patterns = %{
      ...>   sku: ~r/SKU-\\d+/,
      ...>   order: ~r/ORD-\\d+/
      ...> }
      iex> request = %{
      ...>   "uri" => "https://api.example.com/orders/ORD-123",
      ...>   "query_string" => "",
      ...>   "body" => "SKU-456 for ORD-123"
      ...> }
      iex> extract_from_request(request, patterns)
      %{sku: ["SKU-456"], order: ["ORD-123", "ORD-123"]}

  ## Response Scanning

  The `scan_response/2` function determines which request variables also appear
  in the response, so we know which ones to template:

      iex> request_vars = %{sku: ["0234-3455", "0344-4456"]}
      iex> response = %{"body_json" => %{"result" => "SKU 0234-3455 found"}}
      iex> scan_response(response, request_vars)
      MapSet.new(["sku.0"])

  ## Pattern Overlap

  When multiple patterns match the same text, the most specific (longest match) wins:

      iex> patterns = %{
      ...>   id: ~r/\\d+/,
      ...>   sku: ~r/SKU-\\d{4}/
      ...> }
      iex> extract_from_string("Item SKU-1234", patterns)
      %{sku: ["SKU-1234"]}  # sku pattern wins over id
  """

  @doc """
  Extracts template variables from a request using the provided patterns.

  Scans URI path, query parameters, and body in that order, collecting all matches
  for each pattern.

  ## Parameters

  - `request` - Request map with "uri", "query_string", and body fields
  - `patterns` - Map of `%{pattern_name => regex}`, e.g., `%{sku: ~r/\\d{4}-\\d{4}/}`

  ## Returns

  Map of `%{pattern_name => [match1, match2, ...]}` with matches in extraction order

  ## Examples

      iex> patterns = %{sku: ~r/\\d{4}-\\d{4}/}
      iex> request = %{
      ...>   "uri" => "https://api.example.com/products/1234-5678",
      ...>   "query_string" => "related=9999-8888",
      ...>   "body" => "Also check 7777-6666"
      ...> }
      iex> extract_from_request(request, patterns)
      %{sku: ["1234-5678", "9999-8888", "7777-6666"]}
  """
  @spec extract_from_request(map(), map()) :: map()
  def extract_from_request(request, patterns) do
    # Extract in order: URI → query → body
    uri_matches = extract_from_string(request["uri"] || "", patterns)
    query_matches = extract_from_string(request["query_string"] || "", patterns)
    body_matches = extract_from_body(request, patterns)

    # Merge matches in order
    merge_extractions([uri_matches, query_matches, body_matches])
  end

  @doc """
  Extracts template variables from a response using the provided patterns.

  ## Parameters

  - `response` - Response map with body fields
  - `patterns` - Map of `%{pattern_name => regex}`

  ## Returns

  Map of `%{pattern_name => [match1, match2, ...]}`

  ## Examples

      iex> patterns = %{sku: ~r/\\d{4}-\\d{4}/}
      iex> response = %{
      ...>   "body_json" => %{"sku" => "1234-5678", "count" => 5}
      ...> }
      iex> extract_from_response(response, patterns)
      %{sku: ["1234-5678"]}
  """
  @spec extract_from_response(map(), map()) :: map()
  def extract_from_response(response, patterns) do
    extract_from_body(response, patterns)
  end

  @doc """
  Scans a response to find which request variables appear in it.

  This determines which variables should be templated in both request and response
  (true template variables) vs. which only appear in request (wildcards).

  ## Parameters

  - `response` - Response map with body fields
  - `request_vars` - Map of variables extracted from request, e.g., `%{sku: ["1234", "5678"]}`

  ## Returns

  MapSet of variable references that appear in response, e.g., `MapSet.new(["sku.0", "sku.1"])`

  ## Examples

      iex> request_vars = %{sku: ["1234-5678", "9999-8888"]}
      iex> response = %{"body" => "Found SKU 1234-5678"}
      iex> scan_response(response, request_vars)
      MapSet.new(["sku.0"])

      iex> request_vars = %{sku: ["1234-5678", "9999-8888"]}
      iex> response = %{"body_json" => %{"items" => ["1234-5678", "9999-8888"]}}
      iex> scan_response(response, request_vars)
      MapSet.new(["sku.0", "sku.1"])
  """
  @spec scan_response(map(), map()) :: MapSet.t()
  def scan_response(response, request_vars) do
    response_text = extract_response_text(response)

    Enum.reduce(request_vars, MapSet.new(), fn {var_name, values}, acc ->
      values
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {value, index}, inner_acc ->
        # Check if this specific value appears in the response
        if String.contains?(response_text, value) do
          MapSet.put(inner_acc, "#{var_name}.#{index}")
        else
          inner_acc
        end
      end)
    end)
  end

  @doc """
  Extracts matches from a string using the provided patterns.

  ## Parameters

  - `string` - The string to scan
  - `patterns` - Map of `%{pattern_name => regex}`

  ## Returns

  Map of `%{pattern_name => [match1, match2, ...]}`

  ## Examples

      iex> patterns = %{sku: ~r/SKU-\\d+/, order: ~r/ORD-\\d+/}
      iex> extract_from_string("Order ORD-123 for SKU-456", patterns)
      %{sku: ["SKU-456"], order: ["ORD-123"]}

      iex> patterns = %{code: ~r/\\d{4}/}
      iex> extract_from_string("Codes 1234 and 5678", patterns)
      %{code: ["1234", "5678"]}
  """
  @spec extract_from_string(String.t(), map()) :: map()
  def extract_from_string(string, patterns) when is_binary(string) do
    # Find all matches with positions to resolve overlaps
    all_matches =
      Enum.flat_map(patterns, fn {name, pattern} ->
        pattern
        |> Regex.scan(string, return: :index)
        |> Enum.map(fn
          [{start, length} | _] ->
            match_text = String.slice(string, start, length)

            %{
              name: name,
              text: match_text,
              start: start,
              length: length
            }
        end)
        # Filter out empty matches
        |> Enum.reject(fn match -> match.text == "" end)
      end)

    # Resolve overlaps: longest match wins
    non_overlapping = resolve_overlaps(all_matches)

    # Group by pattern name, preserving order
    non_overlapping
    |> Enum.group_by(& &1.name, & &1.text)
    |> Map.new()
  end

  # Resolves overlapping matches by keeping the longest match at each position.
  # When multiple patterns match the same text with the same length,
  # the winner is deterministic: alphabetically first pattern name wins.
  defp resolve_overlaps(matches) do
    matches
    |> Enum.sort_by(& &1.start)
    |> Enum.reduce([], fn match, acc ->
      # Check if this match overlaps with any accepted match
      overlaps? =
        Enum.any?(acc, fn accepted ->
          ranges_overlap?(
            {match.start, match.start + match.length - 1},
            {accepted.start, accepted.start + accepted.length - 1}
          )
        end)

      if overlaps? do
        # Find the overlapping match(es) and keep the longest
        {overlapping, non_overlapping} =
          Enum.split_with(acc, fn accepted ->
            ranges_overlap?(
              {match.start, match.start + match.length - 1},
              {accepted.start, accepted.start + accepted.length - 1}
            )
          end)

        # Keep the longest among all overlapping matches.
        # For deterministic behavior when lengths are equal,
        # use alphabetically first pattern name as tie-breaker.
        longest =
          [match | overlapping]
          |> Enum.sort_by(fn m -> {-m.length, to_string(m.name)} end)
          |> hd()

        [longest | non_overlapping]
      else
        [match | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp ranges_overlap?({start1, end1}, {start2, end2}) do
    start1 <= end2 and start2 <= end1
  end

  # Private helpers

  defp extract_from_body(data, patterns) do
    cond do
      Map.has_key?(data, "body_json") ->
        # Extract from JSON body by serializing first
        case Jason.encode(data["body_json"]) do
          {:ok, json_text} -> extract_from_string(json_text, patterns)
          {:error, _} -> %{}
        end

      Map.has_key?(data, "body") ->
        # Extract from text body
        extract_from_string(data["body"] || "", patterns)

      Map.has_key?(data, "body_blob") ->
        # Extract from binary body (decode base64 first)
        case Base.decode64(data["body_blob"]) do
          {:ok, blob_text} -> extract_from_string(blob_text, patterns)
          :error -> %{}
        end

      true ->
        %{}
    end
  end

  defp extract_response_text(response) do
    cond do
      Map.has_key?(response, "body_json") ->
        case Jason.encode(response["body_json"]) do
          {:ok, json_text} -> json_text
          {:error, _} -> ""
        end

      Map.has_key?(response, "body") ->
        response["body"] || ""

      Map.has_key?(response, "body_blob") ->
        case Base.decode64(response["body_blob"]) do
          {:ok, blob_text} -> blob_text
          :error -> ""
        end

      true ->
        ""
    end
  end

  defp merge_extractions(extraction_list) do
    Enum.reduce(extraction_list, %{}, fn extraction, acc ->
      Map.merge(acc, extraction, fn _key, list1, list2 ->
        list1 ++ list2
      end)
    end)
  end
end
