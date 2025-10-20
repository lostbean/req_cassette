defmodule ReqCassette.Template.Debug do
  @moduledoc """
  Formats debugging information for template matching failures.

  When a template match fails during replay, this module provides detailed diff output
  to help developers understand what went wrong and how to fix it.

  ## Example Output

  ```
  Template match failed for cassette "sku_lookup"

  Expected template structure:
    Method: GET
    URI: https://api.example.com/sku/{{sku.0}}
    Body: List SKU {{sku.0}} separated from SKU {{sku.1}}

  Incoming request (templated):
    Method: GET
    URI: https://api.example.com/sku/{{sku.0}}
    Body: List SKU {{sku.0}} but exclude SKU {{sku.1}}
                               ^^^^^^^^^^^
                               Difference detected here

  Extracted variables:
    sku.0 = "6785-9443"
    sku.1 = "3488-3234"

  Hint: The request structure changed. Update cassette or adjust patterns.
  ```
  """

  @doc """
  Formats a detailed diff for a template match failure.

  ## Parameters

  - `cassette_request` - The templated request from the cassette
  - `incoming_request` - The templated incoming request
  - `diff` - The diff information from the matcher (what field differs)
  - `variables` - The extracted variables from the incoming request

  ## Returns

  A formatted string with the diff information

  ## Examples

      iex> cassette_req = %{
      ...>   "method" => "GET",
      ...>   "uri" => "https://api.example.com/sku/{{sku.0}}",
      ...>   "body" => "Get {{sku.0}}"
      ...> }
      iex> incoming_req = %{
      ...>   "method" => "POST",
      ...>   "uri" => "https://api.example.com/sku/{{sku.0}}",
      ...>   "body" => "Get {{sku.0}}"
      ...> }
      iex> diff = %{field: "method", expected: "GET", actual: "POST"}
      iex> variables = %{sku: ["1234"]}
      iex> message = format_diff(cassette_req, incoming_req, diff, variables)
      iex> String.contains?(message, "Method mismatch")
      true
  """
  @spec format_diff(map(), map(), map(), map()) :: String.t()
  def format_diff(cassette_request, incoming_request, diff, variables) do
    """
    Template match failed

    Expected template structure:
    #{format_request(cassette_request)}

    Incoming request (templated):
    #{format_request(incoming_request)}

    Difference detected:
    #{format_difference(diff)}

    Extracted variables:
    #{format_variables(variables)}

    Hint: #{suggest_fix(diff)}
    """
  end

  # Private helpers

  defp format_request(request) do
    [
      "  Method: #{request["method"] || "?"}",
      "  URI: #{request["uri"] || "?"}",
      format_query(request),
      format_body(request)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_query(%{"query_string" => query}) when query != nil and query != "" do
    "  Query: #{query}"
  end

  defp format_query(_), do: nil

  defp format_body(request) do
    cond do
      Map.has_key?(request, "body_json") ->
        json = Jason.encode!(request["body_json"], pretty: true)
        "  Body (JSON):\n#{indent(json, 4)}"

      Map.has_key?(request, "body") and request["body"] != "" ->
        "  Body: #{request["body"]}"

      true ->
        nil
    end
  end

  defp format_difference(%{field: "method", expected: expected, actual: actual}) do
    """
      Field: method
      Expected: #{expected}
      Actual:   #{actual}
    """
  end

  defp format_difference(%{field: "uri", expected: expected, actual: actual}) do
    """
      Field: uri
      Expected: #{expected}
      Actual:   #{actual}
    """
  end

  defp format_difference(%{field: "query_string", expected: expected, actual: actual}) do
    """
      Field: query_string
      Expected: #{expected}
      Actual:   #{actual}
    """
  end

  defp format_difference(%{field: "body", expected: expected, actual: actual}) do
    # Try to show a visual diff if both are similar
    if String.length(expected) < 500 and String.length(actual) < 500 do
      """
        Field: body
        Expected: #{expected}
        Actual:   #{actual}
      """
    else
      """
        Field: body
        Expected length: #{String.length(expected)} chars
        Actual length:   #{String.length(actual)} chars
        (Bodies too long to display fully)
      """
    end
  end

  defp format_difference(diff) do
    inspect(diff, pretty: true)
  end

  defp format_variables(variables) do
    if map_size(variables) == 0 do
      "  (none)"
    else
      variables
      |> Enum.flat_map(fn {name, values} ->
        values
        |> Enum.with_index()
        |> Enum.map(fn {val, idx} ->
          "  #{name}.#{idx} = #{inspect(val)}"
        end)
      end)
      |> Enum.join("\n")
    end
  end

  defp suggest_fix(%{field: "method"}) do
    "HTTP method changed. Check if you're using the right method (GET vs POST, etc.)."
  end

  defp suggest_fix(%{field: "uri"}) do
    "URI path changed. Check if the endpoint path is different or if patterns need adjustment."
  end

  defp suggest_fix(%{field: "query_string"}) do
    "Query parameters changed. Check if parameter names or structure differs."
  end

  defp suggest_fix(%{field: "body"}) do
    "Request body structure changed. Update cassette or adjust patterns to match new structure."
  end

  defp suggest_fix(_) do
    "Request structure changed. Update cassette or adjust patterns."
  end

  defp indent(text, spaces) do
    prefix = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map(&"#{prefix}#{&1}")
    |> Enum.join("\n")
  end
end
