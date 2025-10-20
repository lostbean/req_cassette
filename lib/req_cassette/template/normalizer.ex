defmodule ReqCassette.Template.Normalizer do
  @moduledoc """
  Normalizes request and response data for predictable template variable extraction.

  To ensure consistent positional indexing with `{{var.0}}`, `{{var.1}}`, etc., this module
  normalizes data before extraction by sorting JSON object keys and query parameters
  alphabetically, while preserving the semantic order of arrays and URI paths.

  ## Why Normalization Matters

  Positional markers like `{{sku.0}}` rely on consistent extraction order. Without
  sorting, minor changes in JSON key order or query param order would break template matching.

  ### Problem without normalization

      # Recording
      Request: {"product": "SKU-1234", "category": "tools"}
      Extracted order: ["SKU-1234"]  # JSON parser happened to iterate product first
      Template: {{sku.0}} = "SKU-1234"

      # Replay - same data, different key order
      Request: {"category": "tools", "product": "SKU-5678"}
      Extracted order: Could differ!
      Template: {{sku.0}} might not match ❌

  ### Solution with normalization

      # Both recording and replay
      1. Sort JSON keys: {"category": "tools", "product": "SKU-XXXX"}
      2. Extract in sorted order: consistently finds product SKU
      3. Positional markers work reliably ✅

  ## Normalization Rules

  - ✅ **JSON object keys** - Sorted alphabetically (recursive)
  - ✅ **Query parameters** - Sorted alphabetically by name
  - ❌ **JSON arrays** - Order preserved (arrays are ordered data structures)
  - ❌ **URI path** - Order preserved (paths have semantic ordering)

  ## Examples

      # JSON normalization
      iex> normalize_json(%{"z" => 1, "a" => 2, "m" => 3})
      %{"a" => 2, "m" => 3, "z" => 1}

      iex> normalize_json(%{"b" => %{"y" => 1, "x" => 2}, "a" => 3})
      %{"a" => 3, "b" => %{"x" => 2, "y" => 1}}

      # Arrays preserve order
      iex> normalize_json([3, 1, 2])
      [3, 1, 2]

      # Query string normalization
      iex> normalize_query_string("z=1&a=2&m=3")
      "a=2&m=3&z=1"

      iex> normalize_query_string("")
      ""

  ## Usage

  This module is used internally during template extraction to ensure
  consistent ordering:

      # During recording
      normalized_request = Normalizer.normalize_request(request)
      variables = Extractor.extract(normalized_request, patterns)

      # During replay
      normalized_request = Normalizer.normalize_request(request)
      variables = Extractor.extract(normalized_request, patterns)
      # Same normalization = same extraction order = reliable matching ✅
  """

  @doc """
  Normalizes a request map for predictable template extraction.

  Sorts JSON bodies and query parameters while preserving URI path and array order.

  ## Parameters

  - `request` - Request map with keys: "method", "uri", "query_string", "headers", "body_*"

  ## Returns

  Normalized request map with sorted JSON and query params

  ## Examples

      iex> request = %{
      ...>   "method" => "GET",
      ...>   "uri" => "https://api.example.com/path",
      ...>   "query_string" => "z=1&a=2",
      ...>   "body_json" => %{"z" => 1, "a" => 2}
      ...> }
      iex> normalized = normalize_request(request)
      iex> normalized["query_string"]
      "a=2&z=1"
      iex> normalized["body_json"]
      %{"a" => 2, "z" => 1}
  """
  @spec normalize_request(map()) :: map()
  def normalize_request(request) when is_map(request) do
    request
    |> normalize_query_in_map()
    |> normalize_body_in_map()
  end

  @doc """
  Normalizes a response map for predictable template extraction.

  Sorts JSON bodies while preserving array order.

  ## Parameters

  - `response` - Response map with keys: "status", "headers", "body_*"

  ## Returns

  Normalized response map with sorted JSON

  ## Examples

      iex> response = %{
      ...>   "status" => 200,
      ...>   "body_json" => %{"z" => 1, "a" => 2}
      ...> }
      iex> normalized = normalize_response(response)
      iex> normalized["body_json"]
      %{"a" => 2, "z" => 1}
  """
  @spec normalize_response(map()) :: map()
  def normalize_response(response) when is_map(response) do
    normalize_body_in_map(response)
  end

  @doc """
  Normalizes JSON data by sorting object keys alphabetically (recursive).

  Arrays preserve their order. Only maps (JSON objects) are sorted.

  ## Parameters

  - `data` - JSON data (map, list, or primitive)

  ## Returns

  Normalized data with sorted object keys

  ## Examples

      iex> normalize_json(%{"c" => 1, "a" => 2, "b" => 3})
      %{"a" => 2, "b" => 3, "c" => 1}

      iex> normalize_json(%{"outer" => %{"z" => 1, "a" => 2}})
      %{"outer" => %{"a" => 2, "z" => 1}}

      iex> normalize_json([%{"b" => 1, "a" => 2}, %{"d" => 3, "c" => 4}])
      [%{"a" => 2, "b" => 1}, %{"c" => 4, "d" => 3}]

      iex> normalize_json([3, 1, 2])
      [3, 1, 2]

      iex> normalize_json("text")
      "text"

      iex> normalize_json(123)
      123
  """
  @spec normalize_json(term()) :: term()
  def normalize_json(data) when is_map(data) do
    data
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, normalize_json(value)} end)
    |> Map.new()
  end

  def normalize_json(data) when is_list(data) do
    # Preserve array order, but recurse into elements
    Enum.map(data, &normalize_json/1)
  end

  def normalize_json(data), do: data

  @doc """
  Normalizes a query string by sorting parameters alphabetically.

  ## Parameters

  - `query_string` - Query string like "z=1&a=2"

  ## Returns

  Sorted query string like "a=2&z=1"

  ## Examples

      iex> normalize_query_string("z=1&a=2&m=3")
      "a=2&m=3&z=1"

      iex> normalize_query_string("single=value")
      "single=value"

      iex> normalize_query_string("")
      ""

      iex> normalize_query_string("b=2&a=1&a=3")
      "a=1&a=3&b=2"
  """
  @spec normalize_query_string(String.t()) :: String.t()
  def normalize_query_string(""), do: ""
  def normalize_query_string(nil), do: ""

  def normalize_query_string(query_string) when is_binary(query_string) do
    query_string
    |> String.split("&", trim: true)
    |> Enum.sort()
    |> Enum.join("&")
  end

  # Private helpers

  defp normalize_query_in_map(map) do
    if Map.has_key?(map, "query_string") do
      Map.update!(map, "query_string", &normalize_query_string/1)
    else
      map
    end
  end

  defp normalize_body_in_map(map) do
    cond do
      Map.has_key?(map, "body_json") ->
        Map.update!(map, "body_json", &normalize_json/1)

      # "body" (text) and "body_blob" (binary) don't need normalization
      true ->
        map
    end
  end
end
