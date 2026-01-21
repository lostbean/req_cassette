defmodule ReqCassette.Template.Matcher do
  @moduledoc """
  Matches templated requests by comparing their structure (template markers), not values.

  During replay, we create a templated version of the incoming request and compare it
  to the cassette's templated request. If the structures match (same template markers
  in the same positions), we can use the cassette.

  ## Key Insight

  We match on **template structure** (`{{sku.0}}`), not the actual values
  (`0234-3455` vs `6785-9443`).

  ## Examples

      # Recording
      Request: "List SKU 0234-3455 and SKU 0344-4456"
      Templated: "List SKU {{sku.0}} and SKU {{sku.1}}"

      # Replay with different SKUs
      Request: "List SKU 6785-9443 and SKU 3488-3234"
      Templated: "List SKU {{sku.0}} and SKU {{sku.1}}"

      # Match: YES ✅ - Same structure, different values

      # Replay with different structure
      Request: "List SKU 6785-9443 but exclude SKU 3488-3234"
      Templated: "List SKU {{sku.0}} but exclude SKU {{sku.1}}"

      # Match: NO ❌ - Different structure ("and" vs "but exclude")

  ## What Gets Matched

  The matcher compares templated request maps on these fields:
  - `"method"` - HTTP method
  - `"uri"` - Full URI (with template markers if applicable)
  - `"query_string"` - Query string (with template markers)
  - `"body"` or `"body_json"` - Body content (with template markers)

  Headers are NOT compared (to avoid auth token issues).

  ## Normalization

  Both requests should be normalized before templating to ensure consistent
  comparison (see `ReqCassette.Template.Normalizer`).
  """

  @doc """
  Checks if two templated requests match.

  Compares the structure of templated requests, ignoring actual values and
  only looking at template markers and static text.

  ## Parameters

  - `cassette_request` - Templated request from cassette (with markers like `{{sku.0}}`)
  - `incoming_request` - Templated version of incoming request

  ## Returns

  - `:match` if structures are identical
  - `{:error, diff}` if they don't match, with diff details

  ## Examples

      iex> cassette_req = %{
      ...>   "method" => "GET",
      ...>   "uri" => "https://api.example.com/sku/{{sku.0}}",
      ...>   "body" => ""
      ...> }
      iex> incoming_req = %{
      ...>   "method" => "GET",
      ...>   "uri" => "https://api.example.com/sku/{{sku.0}}",
      ...>   "body" => ""
      ...> }
      iex> match?(cassette_req, incoming_req)
      :match

      iex> cassette_req = %{
      ...>   "method" => "GET",
      ...>   "uri" => "https://api.example.com/sku/{{sku.0}}"
      ...> }
      iex> incoming_req = %{
      ...>   "method" => "POST",
      ...>   "uri" => "https://api.example.com/sku/{{sku.0}}"
      ...> }
      iex> match?(cassette_req, incoming_req)
      {:error, %{field: "method", expected: "GET", actual: "POST"}}
  """
  @spec match?(map(), map(), [atom()]) :: :match | {:error, map()}
  def match?(cassette_request, incoming_request, match_on \\ [:method, :uri, :query, :body]) do
    # Compare only the fields specified in match_on
    # This honors the user's match_requests_on option for templated cassettes
    # Return the first mismatch encountered (in match_on order)
    Enum.reduce_while(match_on, :match, fn matcher, _acc ->
      case check_matcher(matcher, cassette_request, incoming_request) do
        :ok -> {:cont, :match}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Check a single matcher, returning :ok or {:error, details}
  defp check_matcher(:method, cassette_request, incoming_request) do
    if methods_match?(cassette_request, incoming_request) do
      :ok
    else
      {:error,
       %{
         field: "method",
         expected: cassette_request["method"],
         actual: incoming_request["method"]
       }}
    end
  end

  defp check_matcher(:uri, cassette_request, incoming_request) do
    if uris_match?(cassette_request, incoming_request) do
      :ok
    else
      {:error,
       %{
         field: "uri",
         expected: cassette_request["uri"],
         actual: incoming_request["uri"]
       }}
    end
  end

  defp check_matcher(:query, cassette_request, incoming_request) do
    if query_strings_match?(cassette_request, incoming_request) do
      :ok
    else
      {:error,
       %{
         field: "query_string",
         expected: cassette_request["query_string"] || "",
         actual: incoming_request["query_string"] || ""
       }}
    end
  end

  defp check_matcher(:body, cassette_request, incoming_request) do
    if bodies_match?(cassette_request, incoming_request) do
      :ok
    else
      {:error,
       %{
         field: "body",
         expected: extract_body_for_comparison(cassette_request),
         actual: extract_body_for_comparison(incoming_request)
       }}
    end
  end

  # Ignore other matchers (like :headers) for template matching
  defp check_matcher(_other, _cassette_request, _incoming_request), do: :ok

  # Private helpers

  defp methods_match?(req1, req2) do
    method1 = req1["method"] || ""
    method2 = req2["method"] || ""
    String.upcase(method1) == String.upcase(method2)
  end

  defp uris_match?(req1, req2) do
    uri1 = req1["uri"] || ""
    uri2 = req2["uri"] || ""
    uri1 == uri2
  end

  defp query_strings_match?(req1, req2) do
    qs1 = req1["query_string"] || ""
    qs2 = req2["query_string"] || ""
    qs1 == qs2
  end

  defp bodies_match?(req1, req2) do
    body1 = extract_body_for_comparison(req1)
    body2 = extract_body_for_comparison(req2)
    body1 == body2
  end

  defp extract_body_for_comparison(request) do
    cond do
      Map.has_key?(request, "body_json") ->
        # For JSON bodies, compare the normalized JSON structure
        # (already templated and normalized)
        Jason.encode!(request["body_json"])

      Map.has_key?(request, "body") ->
        request["body"] || ""

      Map.has_key?(request, "body_blob") ->
        request["body_blob"] || ""

      true ->
        ""
    end
  end
end
