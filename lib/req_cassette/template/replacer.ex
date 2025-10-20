defmodule ReqCassette.Template.Replacer do
  @moduledoc """
  Creates and applies template markers by replacing values with `{{var.N}}` placeholders.

  This module handles:
  - Creating templates from original content by replacing extracted values with markers
  - Applying templates by substituting new values into markers
  - Type safety for JSON bodies (only template string values)
  - Escape handling for literal braces

  ## Template Marker Format

  Template markers use the format `{{name.index}}` where:
  - `name` is the pattern name (e.g., `sku`, `order_id`)
  - `index` is the instance identifier for each unique value (value-based, not position-based)

  **Important:** Duplicate values get the same index!

  Examples:
  ```
  # Different values → different indices
  Variables: %{sku: ["0234-3455", "0344-4456"]}
  Markers: {{sku.0}}, {{sku.1}}

  # Duplicate values → same index
  Variables: %{sku: ["0234-3455", "0234-3455"]}
  Text: "SKU 0234-3455 and SKU 0234-3455 again"
  Result: "SKU {{sku.0}} and {{sku.0}} again"
  ```

  The index identifies the unique VALUE, not its position. This means:
  - Same value appearing multiple times → all get the same marker
  - Only unique values get different indices

  ## Type Safety for JSON

  When templating JSON bodies:
  - **String values** - Templated: `"SKU {{sku.0}}"`
  - **Numbers** - NOT templated: `5` stays as `5`
  - **Booleans** - NOT templated: `true` stays as `true`
  - **Null** - NOT templated: `null` stays as `null`
  - **Arrays** - Elements processed recursively
  - **Objects** - Values processed recursively, keys optionally

  This ensures generated JSON is always valid and type-safe.

  ## Examples

      # Create text template
      iex> variables = %{sku: ["1234-5678", "9999-8888"]}
      iex> content = "Get SKU 1234-5678 and exclude SKU 9999-8888"
      iex> create_template(content, variables)
      "Get SKU {{sku.0}} and exclude SKU {{sku.1}}"

      # Create JSON template (only strings templated)
      iex> variables = %{sku: ["1234-5678"]}
      iex> json = %{"sku" => "1234-5678", "count" => 5, "active" => true}
      iex> create_json_template(json, variables)
      %{"sku" => "{{sku.0}}", "count" => 5, "active" => true}

      # Apply template
      iex> template = "Get SKU {{sku.0}} and exclude SKU {{sku.1}}"
      iex> variables = %{sku: ["5555-6666", "7777-8888"]}
      iex> apply_template(template, variables)
      "Get SKU 5555-6666 and exclude SKU 7777-8888"

  ## Options

  - `:scope` - Which variables to template:
    - `:all` - Template all variables (default)
    - MapSet of var references like `MapSet.new(["sku.0"])` - Template only these
  - `:allow_key_templates` - Allow templating JSON object keys (default: false)
  """

  alias ReqCassette.Template.Escape

  @doc """
  Creates a template from request/response data by replacing values with markers.

  This is the main entry point that handles both JSON and text bodies.

  ## Parameters

  - `data` - Request or response map
  - `variables` - Extracted variables map like `%{sku: ["1234", "5678"]}`
  - `opts` - Options:
    - `:scope` - `:all` or MapSet of variable references to template
    - `:allow_key_templates` - Allow JSON key templating (default: false)

  ## Returns

  Data map with values replaced by template markers

  ## Examples

      iex> data = %{"body" => "Get SKU 1234-5678"}
      iex> variables = %{sku: ["1234-5678"]}
      iex> create_template_from_data(data, variables)
      %{"body" => "Get SKU {{sku.0}}"}

      iex> data = %{"body_json" => %{"sku" => "1234-5678", "count" => 5}}
      iex> variables = %{sku: ["1234-5678"]}
      iex> create_template_from_data(data, variables)
      %{"body_json" => %{"sku" => "{{sku.0}}", "count" => 5}}
  """
  @spec create_template_from_data(map(), map(), keyword()) :: map()
  def create_template_from_data(data, variables, opts \\ []) do
    # Template body fields
    data_with_body =
      cond do
        Map.has_key?(data, "body_json") ->
          # JSON body - use type-safe JSON templating
          templated_json = create_json_template(data["body_json"], variables, opts)
          Map.put(data, "body_json", templated_json)

        Map.has_key?(data, "body") ->
          # Text body - template anywhere in string
          templated_text = create_template(data["body"], variables, opts)
          Map.put(data, "body", templated_text)

        Map.has_key?(data, "body_blob") ->
          # Binary body - not templated (may not be valid UTF-8)
          # Templating only works with text content; binary blobs are preserved as-is
          data

        true ->
          data
      end

    # Also template URI and query_string if present (for requests)
    data_with_body
    |> template_field_if_present("uri", variables, opts)
    |> template_field_if_present("query_string", variables, opts)
  end

  # Helper to template a specific field if it exists
  defp template_field_if_present(data, field, variables, opts) do
    if Map.has_key?(data, field) and is_binary(data[field]) do
      templated = create_template(data[field], variables, opts)
      Map.put(data, field, templated)
    else
      data
    end
  end

  @doc """
  Creates a template from JSON data with type safety.

  Only string values are templated. Numbers, booleans, null, and non-string types
  are preserved as-is to ensure valid JSON output.

  ## Parameters

  - `json_data` - The JSON data (map or list)
  - `variables` - Extracted variables
  - `opts` - Options (`:scope`, `:allow_key_templates`)

  ## Returns

  JSON data with string values replaced by template markers

  ## Examples

      iex> json = %{"sku" => "1234", "count" => 5, "active" => true}
      iex> variables = %{sku: ["1234"]}
      iex> create_json_template(json, variables)
      %{"sku" => "{{sku.0}}", "count" => 5, "active" => true}

      iex> json = %{"items" => [%{"id" => "ABC"}, %{"id" => "XYZ"}]}
      iex> variables = %{id: ["ABC", "XYZ"]}
      iex> create_json_template(json, variables)
      %{"items" => [%{"id" => "{{id.0}}"}, %{"id" => "{{id.1}}"}]}
  """
  @spec create_json_template(term(), map(), keyword()) :: term()
  def create_json_template(json_data, variables, opts \\ [])

  def create_json_template(data, variables, opts) when is_map(data) do
    allow_key_templates = Keyword.get(opts, :allow_key_templates, false)

    Map.new(data, fn {key, value} ->
      # Optionally template the key
      new_key =
        if allow_key_templates and is_binary(key) do
          replace_in_string(key, variables, opts)
        else
          key
        end

      # Always recurse into the value
      new_value = create_json_template(value, variables, opts)

      {new_key, new_value}
    end)
  end

  def create_json_template(data, variables, opts) when is_list(data) do
    Enum.map(data, fn item ->
      create_json_template(item, variables, opts)
    end)
  end

  def create_json_template(data, variables, opts) when is_binary(data) do
    # Only template string values
    replace_in_string(data, variables, opts)
  end

  # Non-string types: preserve as-is for type safety
  def create_json_template(data, _variables, _opts) when is_number(data), do: data
  def create_json_template(data, _variables, _opts) when is_boolean(data), do: data
  def create_json_template(nil, _variables, _opts), do: nil

  @doc """
  Creates a template from text content by replacing values with markers.

  Unlike JSON templating, this can replace values anywhere in the string.

  ## Parameters

  - `content` - The text content
  - `variables` - Extracted variables
  - `opts` - Options (`:scope`)

  ## Returns

  Text with values replaced by template markers

  ## Examples

      iex> content = "Order ORD-123 ships with SKU-456"
      iex> variables = %{order: ["ORD-123"], sku: ["SKU-456"]}
      iex> create_template(content, variables)
      "Order {{order.0}} ships with {{sku.0}}"
  """
  @spec create_template(String.t(), map(), keyword()) :: String.t()
  def create_template(content, variables, opts \\ []) when is_binary(content) do
    # Skip templating for invalid UTF-8 (binary data) to avoid crashes
    if not String.valid?(content) do
      content
    else
      # First escape any literal braces in the original content
      escaped_content = Escape.escape(content)

      # Then replace values with template markers
      replace_in_string(escaped_content, variables, opts)
    end
  end

  @doc """
  Applies a template by substituting variables with new values.

  This is used during replay to inject new request values into the templated response.

  ## Parameters

  - `data` - Templated data map (request or response)
  - `variables` - New variables to substitute, e.g., `%{sku: ["5555", "6666"]}`

  ## Returns

  Data with template markers replaced by actual values

  ## Examples

      iex> data = %{"body" => "Get SKU {{sku.0}}"}
      iex> variables = %{sku: ["9999"]}
      iex> apply_template_to_data(data, variables)
      %{"body" => "Get SKU 9999"}

      iex> data = %{"body_json" => %{"sku" => "{{sku.0}}", "count" => 5}}
      iex> variables = %{sku: ["7777"]}
      iex> apply_template_to_data(data, variables)
      %{"body_json" => %{"sku" => "7777", "count" => 5}}
  """
  @spec apply_template_to_data(map(), map()) :: map()
  def apply_template_to_data(data, variables) do
    cond do
      Map.has_key?(data, "body_json") ->
        substituted_json = substitute_in_json(data["body_json"], variables)
        Map.put(data, "body_json", substituted_json)

      Map.has_key?(data, "body") ->
        substituted_text = substitute_in_string(data["body"], variables)
        Map.put(data, "body", substituted_text)

      Map.has_key?(data, "body_blob") ->
        blob = Base.decode64!(data["body_blob"])
        substituted = substitute_in_string(blob, variables)
        Map.put(data, "body_blob", Base.encode64(substituted))

      true ->
        data
    end
  end

  @doc """
  Substitutes template markers in JSON data recursively.

  ## Parameters

  - `json_data` - JSON data with template markers
  - `variables` - Variables to substitute

  ## Returns

  JSON data with markers replaced by values

  ## Examples

      iex> json = %{"id" => "{{sku.0}}", "count" => 5}
      iex> variables = %{sku: ["9999"]}
      iex> substitute_in_json(json, variables)
      %{"id" => "9999", "count" => 5}
  """
  @spec substitute_in_json(term(), map()) :: term()
  def substitute_in_json(data, variables) when is_map(data) do
    Map.new(data, fn {key, value} ->
      new_key = if is_binary(key), do: substitute_in_string(key, variables), else: key
      new_value = substitute_in_json(value, variables)
      {new_key, new_value}
    end)
  end

  def substitute_in_json(data, variables) when is_list(data) do
    Enum.map(data, &substitute_in_json(&1, variables))
  end

  def substitute_in_json(data, variables) when is_binary(data) do
    substitute_in_string(data, variables)
  end

  def substitute_in_json(data, _variables), do: data

  @doc """
  Replaces values with template markers in a string.

  ## Parameters

  - `string` - The string to template
  - `variables` - Variables to replace
  - `opts` - Options (`:scope`)

  ## Returns

  String with values replaced by markers

  ## Examples

      iex> replace_in_string("Get 1234 and 5678", %{sku: ["1234", "5678"]})
      "Get {{sku.0}} and {{sku.1}}"
  """
  @spec replace_in_string(String.t(), map(), keyword()) :: String.t()
  def replace_in_string(string, variables, opts \\ []) when is_binary(string) do
    scope = Keyword.get(opts, :scope, :all)

    # Build replacement list: [{value, marker}, ...]
    # Sort by length descending to replace longer values first
    replacements =
      variables
      |> Enum.flat_map(fn {name, values} ->
        values
        |> Enum.with_index()
        |> Enum.map(fn {value, index} ->
          marker = "{{#{name}.#{index}}}"
          var_ref = "#{name}.#{index}"

          # Check if this variable should be templated based on scope
          should_template =
            case scope do
              :all -> true
              %MapSet{} = set -> MapSet.member?(set, var_ref)
              _ -> false
            end

          if should_template do
            {value, marker}
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.sort_by(fn {value, _marker} -> -String.length(value) end)

    # Apply replacements
    Enum.reduce(replacements, string, fn {value, marker}, acc ->
      # Use regex to match whole occurrences
      # Escape special regex characters in the value
      escaped_value = Regex.escape(value)
      String.replace(acc, ~r/#{escaped_value}/, marker)
    end)
  end

  @doc """
  Substitutes template markers with actual values in a string.

  ## Parameters

  - `string` - String with template markers
  - `variables` - Variables to substitute

  ## Returns

  String with markers replaced by values, and literal braces unescaped

  ## Examples

      iex> substitute_in_string("Get {{sku.0}}", %{sku: ["9999"]})
      "Get 9999"

      iex> substitute_in_string("{{sku.0}} and {{sku.1}}", %{sku: ["AAA", "BBB"]})
      "AAA and BBB"
  """
  @spec substitute_in_string(String.t(), map()) :: String.t()
  def substitute_in_string(string, variables) when is_binary(string) do
    # Replace each {{var.N}} marker with its value
    result =
      Enum.reduce(variables, string, fn {name, values}, acc ->
        values
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {value, index}, inner_acc ->
          marker = "{{#{name}.#{index}}}"
          String.replace(inner_acc, marker, value)
        end)
      end)

    # Unescape any literal braces that were escaped
    Escape.unescape(result)
  end
end
