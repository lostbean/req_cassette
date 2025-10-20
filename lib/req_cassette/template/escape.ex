defmodule ReqCassette.Template.Escape do
  @moduledoc """
  Handles escaping and unescaping of template markers to prevent collisions with literal braces.

  When data contains literal `{{` or `}}` sequences, they need to be escaped to avoid
  confusion with template markers like `{{sku.0}}`. This module provides escape/unescape
  functions to handle this safely.

  ## Problem

  If actual response data contains `{{special}}`, it would be confused with a template marker.

  ## Solution

  Escape literal braces during template creation:
  - `{{` → `\\{\\{`
  - `}}` → `\\}\\}`
  - `\\` → `\\\\` (escape the escape character)

  ## Examples

      iex> escape("literal {{value}} and normal text")
      "literal \\\\{\\\\{value\\\\}\\\\} and normal text"

      iex> unescape("literal \\\\{\\\\{value\\\\}\\\\} and normal text")
      "literal {{value}} and normal text"

      # Template markers are not escaped (handled by replacer module)
      iex> escape("SKU {{sku.0}} is active")
      "SKU {{sku.0}} is active"  # Markers stay as-is

      # But literal braces in data are escaped
      iex> data = ~s({"code": "{{special}}", "sku": "1234"})
      iex> escape(data)
      ~s({"code": "\\\\{\\\\{special\\\\}\\\\}", "sku": "1234"})

  ## Escaping Order

  When creating templates:
  1. Escape literal braces in original content first
  2. Then create template markers (by replacer module)

  When applying templates:
  1. Substitute template markers with values (by replacer module)
  2. Then unescape literal braces

  This ensures template markers are never confused with literal data.
  """

  @doc """
  Escapes literal `{{`, `}}`, and `\\` sequences in a string.

  ## Parameters

  - `string` - The string to escape

  ## Returns

  String with escaped sequences

  ## Examples

      iex> escape("normal text")
      "normal text"

      iex> escape("has {{literal}} braces")
      "has \\\\{\\\\{literal\\\\}\\\\} braces"

      iex> escape("backslash \\\\ here")
      "backslash \\\\\\\\ here"

      iex> escape("both \\\\ and {{value}}")
      "both \\\\\\\\ and \\\\{\\\\{value\\\\}\\\\}"
  """
  @spec escape(String.t()) :: String.t()
  def escape(string) when is_binary(string) do
    string
    # Escape backslashes first (before adding more backslashes)
    |> String.replace("\\", "\\\\")
    |> String.replace("{{", "\\{\\{")
    |> String.replace("}}", "\\}\\}")
  end

  @doc """
  Unescapes previously escaped `{{`, `}}`, and `\\` sequences.

  ## Parameters

  - `string` - The string with escaped sequences

  ## Returns

  String with sequences restored to original form

  ## Examples

      iex> unescape("normal text")
      "normal text"

      iex> unescape("has \\\\{\\\\{literal\\\\}\\\\} braces")
      "has {{literal}} braces"

      iex> unescape("backslash \\\\\\\\ here")
      "backslash \\\\ here"

      iex> unescape("both \\\\\\\\ and \\\\{\\\\{value\\\\}\\\\}")
      "both \\\\ and {{value}}"
  """
  @spec unescape(String.t()) :: String.t()
  def unescape(string) when is_binary(string) do
    string
    # Unescape in reverse order: braces first, then backslashes
    |> String.replace("\\}\\}", "}}")
    |> String.replace("\\{\\{", "{{")
    |> String.replace("\\\\", "\\")
  end

  @doc """
  Escapes literal braces in a JSON structure recursively.

  This is used for JSON bodies where we need to escape literal braces
  in string values while preserving the JSON structure.

  ## Parameters

  - `data` - The data structure (map, list, or primitive)

  ## Returns

  Data structure with escaped string values

  ## Examples

      iex> escape_json(%{"key" => "{{value}}"})
      %{"key" => "\\\\{\\\\{value\\\\}\\\\}"}

      iex> escape_json(%{"nested" => %{"key" => "{{test}}"}})
      %{"nested" => %{"key" => "\\\\{\\\\{test\\\\}\\\\}"}}

      iex> escape_json(["{{item}}", "normal", 123])
      ["\\\\{\\\\{item\\\\}\\\\}", "normal", 123]
  """
  @spec escape_json(term()) :: term()
  def escape_json(data) when is_map(data) do
    Map.new(data, fn {key, value} ->
      {escape_json(key), escape_json(value)}
    end)
  end

  def escape_json(data) when is_list(data) do
    Enum.map(data, &escape_json/1)
  end

  def escape_json(data) when is_binary(data) do
    escape(data)
  end

  def escape_json(data), do: data

  @doc """
  Unescapes literal braces in a JSON structure recursively.

  ## Parameters

  - `data` - The data structure (map, list, or primitive)

  ## Returns

  Data structure with unescaped string values

  ## Examples

      iex> unescape_json(%{"key" => "\\\\{\\\\{value\\\\}\\\\}"})
      %{"key" => "{{value}}"}

      iex> unescape_json(%{"nested" => %{"key" => "\\\\{\\\\{test\\\\}\\\\}"}})
      %{"nested" => %{"key" => "{{test}}"}}

      iex> unescape_json(["\\\\{\\\\{item\\\\}\\\\}", "normal", 123])
      ["{{item}}", "normal", 123]
  """
  @spec unescape_json(term()) :: term()
  def unescape_json(data) when is_map(data) do
    Map.new(data, fn {key, value} ->
      {unescape_json(key), unescape_json(value)}
    end)
  end

  def unescape_json(data) when is_list(data) do
    Enum.map(data, &unescape_json/1)
  end

  def unescape_json(data) when is_binary(data) do
    unescape(data)
  end

  def unescape_json(data), do: data
end
