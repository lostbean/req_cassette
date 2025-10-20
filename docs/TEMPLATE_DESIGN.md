# ReqCassette Template Design Specification

## Overview

Templates enable **parameterized cassettes** where dynamic values from incoming
requests are automatically substituted into recorded responses during replay.
This allows a single cassette to handle multiple requests with varying
identifiers, codes, or other dynamic values while maintaining the same response
structure.

**Templates are configured per-interaction**, not per-cassette. Each recorded
HTTP interaction in a cassette file can have its own template configuration, or
no templates at all. This allows mixed usage: some interactions templated,
others matched exactly.

**Supported modes:** Templates work with `:record` and `:replay` modes only.

### Use Case Example

**Recording:**

```
Request:  "List components of SKU 0234-3455 but keep SKU 0234-3455 separated from SKU 0344-4456"
Response: {"0234-3455": ["screw", "rod", "plate"], "obs": "SKU 0234-3455 is not active"}
```

**Replay:**

```
Request:  "List components of SKU 6785-9443 but keep SKU 6785-9443 separated from SKU 3488-3234"
Response: {"6785-9443": ["screw", "rod", "plate"], "obs": "SKU 6785-9443 is not active"}
```

The cassette automatically detects `6785-9443` and `3488-3234` from the new
request and substitutes them into the response template.

### Benefits

- **Reduced cassette count** - One cassette handles many variations
- **Test data flexibility** - Use different IDs/codes without re-recording
- **Simplified maintenance** - Update one template instead of many cassettes
- **LLM API testing** - Handle non-deterministic outputs that reference request
  data

---

## Core Concept

### Template Matching Strategy

Templates work by matching on **structure**, not values:

**Recording Phase:**

1. Extract dynamic values from request using patterns (e.g., `~r/\d{4}-\d{4}/`)
2. Replace extracted values with template markers (e.g., `{{sku.0}}`,
   `{{sku.1}}`)
3. Create templated request: `"List SKU {{sku.0}} separated from {{sku.1}}"`
4. Scan response for same values and template them
5. Store both templated request and templated response

**Replay Phase:**

1. Extract dynamic values from incoming request using same patterns
2. Replace with same template markers
3. Create templated incoming request:
   `"List SKU {{sku.0}} separated from
   {{sku.1}}"`
4. **Match:** Does templated incoming request match cassette's templated
   request?
5. If match, substitute new values into cassette's templated response
6. Return substituted response

**Key Insight:** We match on the **template structure** (`{{sku.0}}`), not the
actual values (`0234-3455` vs `6785-9443`).

### JSON and Parameter Sorting for Predictable Extraction

To ensure consistent positional indexing with `{{var.0}}`, `{{var.1}}`, etc.,
ReqCassette normalizes data before extraction.

**Normalization steps:**

1. **JSON objects** - Keys sorted alphabetically (recursively)
2. **Query parameters** - Sorted alphabetically by parameter name
3. **JSON arrays** - Order preserved (arrays have semantic ordering)

**Why sorting matters:**

Positional markers like `{{sku.0}}` rely on consistent extraction order. Without
sorting, minor changes in JSON key order or query param order would break
template matching.

**Example without sorting (fragile):**

```elixir
# Recording
Request: {"product": "SKU-1234", "category": "tools"}
Extracted order: ["SKU-1234"]  # JSON parser happened to iterate product first
Template: {{sku.0}} = "SKU-1234"

# Replay
Request: {"category": "tools", "product": "SKU-5678"}
Extracted order: ["SKU-5678"]  # Different JSON key order, but same result after sorting
Template: {{sku.0}} = "SKU-5678"  ✅ Works!
```

**Example with sorting (robust):**

```elixir
# Both recording and replay
1. Sort JSON keys: {"category": "tools", "product": "SKU-XXXX"}
2. Extract in sorted order: consistently finds product SKU
3. Instance markers assigned deterministically
```

**Sorting scope:**

- ✅ JSON object keys (alphabetically)
- ✅ Query parameters (alphabetically by name)
- ❌ JSON array elements (preserve order - arrays are ordered data structures)
- ❌ URI path segments (preserve order - path has semantic ordering)

**Best practice:**

While sorting helps, **write specific patterns** to avoid relying on order:

```elixir
# Better: Specific pattern
patterns: [sku: ~r/SKU-\d{4}-\d{4}/]  # Won't match "ID-1234"

# Worse: Overly broad pattern
patterns: [id: ~r/\d+/]  # Matches many things, order-dependent
```

**Rationale:**

- **Predictability** - Same template markers always refer to same logical data
- **Robustness** - Insensitive to JSON serialization order
- **User experience** - Reduces surprising template match failures
- **Performance** - Sorting once is cheaper than debugging mismatches

---

## Filter Integration

Templates integrate with ReqCassette's existing filter system to ensure
sensitive data is never exposed in cassette files.

### Filter Order

**Critical: Filters are applied BEFORE template extraction**

```
Request/Response Flow:
1. Apply filter_request / filter_response
2. Extract template variables from filtered content
3. Create templates
4. Save/match cassette
```

### Rationale

This order prevents sensitive data from appearing in template variables or
cassette files:

```elixir
use_cassette "api_test",
  filter_request: fn request ->
    # Remove API key before template extraction
    Map.update!(request, :headers, fn headers ->
      List.keydelete(headers, "authorization", 0)
    end)
  end,
  template: [
    patterns: [order_id: ~r/ORD-\d+/]
  ] do
  # API key is filtered out, so patterns can't accidentally extract it
  Req.get!("https://api.example.com/orders/ORD-12345",
    headers: [{"authorization", "Bearer secret-key"}])
end
```

### Example: Filtering Before Extraction

**Without filter (dangerous):**

```
Request body: {"api_key": "sk-1234567890", "order": "ORD-12345"}
Pattern: ~r/[a-z]{2}-\d+/
Extracted: %{key: ["sk-1234567890", "ORD-12345"]}  # ❌ API key exposed!
```

**With filter (safe):**

```
1. Filter: {"order": "ORD-12345"}  # api_key removed
2. Extract: %{key: ["ORD-12345"]}  # ✅ Only order ID extracted
```

### Best Practices

- **Always filter sensitive data first** - Use `filter_request` and
  `filter_response` to remove secrets before template extraction
- **Filters are your first line of defense** - Don't rely on pattern specificity
  to avoid sensitive data
- **Test your filters** - Verify sensitive data is removed before recording

### Filter + Template Interaction

Filters and templates work together:

1. **Filters** remove what should never be saved (API keys, passwords, PII)
2. **Templates** parameterize what should vary (IDs, SKUs, dates)

Both features complement each other for safe, flexible testing.

---

## Template Variable Rules

Templates are created by scanning both request and response for extracted
values. The location determines how each value is handled:

| Value Location    | Action                  | Rationale                      |
| ----------------- | ----------------------- | ------------------------------ |
| **Request only**  | Template as `{{var.N}}` | Wildcard - allows any value    |
| **Response only** | Keep original value     | Not parameterized, static data |
| **Both**          | Template in both        | True template variable         |

### Example

```
Request:  "List SKU 0234-3455 but exclude SKU 9999-8888"
Response: {"0234-3455": ["screw"], "system_sku": "0000-1111"}
```

**Pattern extraction:** `%{sku: ["0234-3455", "9999-8888"]}`

**Templated request:**

```
"List SKU {{sku.0}} but exclude SKU {{sku.1}}"
```

**Templated response:**

```json
{
  "{{sku.0}}": ["screw"],
  "system_sku": "0000-1111"
}
```

**Note:** `"0000-1111"` stays literal because it only appears in response.

### Rationale

- **Request-only values** act as wildcards for matching flexibility
- **Response-only values** are static parts of the API response
- **Shared values** are the parameterized data we want to template

---

## Pattern Extraction Scope

Patterns are applied to specific parts of the request and response, not
everything.

### What Gets Scanned

Templates extract variables from:

1. **Request/Response Bodies** - The primary content of the HTTP message
2. **Query Parameters** - URL query string parameters
3. **URI Path** - The path component of the URL

### What Does NOT Get Scanned

- **Headers** - Excluded to prevent accidental exposure of sensitive auth tokens
  - Use filters to handle sensitive headers instead
- **HTTP Method** - Static part of request matching
- **Status Code** - Static part of response matching

### Examples by Scope

#### Body Extraction

```elixir
# Request body
"{\"order_id\": \"ORD-12345\"}"

# Pattern
patterns: [order_id: ~r/ORD-\d+/]

# Extracted
%{order_id: ["ORD-12345"]}
```

#### Query Parameter Extraction

```elixir
# Request URL
"https://api.example.com/products?sku=1234-5678&category=tools"

# Pattern
patterns: [sku: ~r/\d{4}-\d{4}/]

# Extracted from query string
%{sku: ["1234-5678"]}
```

#### URI Path Extraction

```elixir
# Request URL
"https://api.example.com/orders/ORD-12345/items"

# Pattern
patterns: [order_id: ~r/ORD-\d+/]

# Extracted from path
%{order_id: ["ORD-12345"]}
```

#### Composite Extraction

Patterns scan **all scopes together**, collecting all matches:

```elixir
# Request
URL:  "https://api.example.com/orders/ORD-11111?ref=ORD-22222"
Body: "{\"related_order\": \"ORD-33333\"}"

# Pattern
patterns: [order_id: ~r/ORD-\d+/]

# Extracted from all scopes (path + query + body)
%{order_id: ["ORD-11111", "ORD-22222", "ORD-33333"]}
```

### Scope Processing Order

Extraction happens in this order to ensure predictable positional indexing:

1. URI path (left to right)
2. Query parameters (alphabetically sorted by key)
3. Request body (depth-first for JSON)

This ensures `{{order_id.0}}`, `{{order_id.1}}`, etc. map consistently.

### Rationale

- **Body/Params/URI** are the dynamic data that typically varies between tests
- **Headers** often contain secrets (API keys, tokens) - filters are safer
- **Limited scope** reduces accidental extraction and improves performance

---

## Escape Sequences for Collision Handling

### Problem

What if actual data contains `{{` or `}}`?

```json
{ "code": "{{special}}", "sku": "0234-3455" }
```

Without escaping, `{{special}}` would be confused with a template marker.

### Solution

Escape literal braces during template creation:

**Escape rules:**

- `{{` → `\{\{`
- `}}` → `\}\}`
- `\` → `\\` (escape the escape character)

**Example:**

```json
// Original response
{"code": "{{special}}", "sku": "0234-3455"}

// After escaping and templating
{"code": "\\{\\{special\\}\\}", "sku": "{{sku.0}}"}

// On replay, after substitution and unescaping
{"code": "{{special}}", "sku": "6785-9443"}
```

### Implementation

```elixir
defmodule ReqCassette.Template.Escape do
  def escape(string) when is_binary(string) do
    string
    |> String.replace("\\", "\\\\")    # Escape backslashes first
    |> String.replace("{{", "\\{\\{")
    |> String.replace("}}", "\\}\\}")
  end

  def unescape(string) when is_binary(string) do
    string
    |> String.replace("\\}\\}", "}}")
    |> String.replace("\\{\\{", "{{")
    |> String.replace("\\\\", "\\")
  end
end
```

---

## Partial Templates

Templates support mixing static and dynamic parts. Behavior differs for JSON vs
text bodies.

### JSON Bodies (`body_type: "template_json"`)

**Default behavior:** Only template **values**, not keys

**Type restriction:** Template markers only appear in **string values**, never
in numbers, booleans, or null.

```json
{
  "body_type": "template_json",
  "body_json": {
    "status": "SKU {{sku.0}} active", // String value templating ✅
    "static_field": "no template", // Static string ✅
    "another_key": "{{sku.1}}", // String value templating ✅
    "count": 5, // Number - NOT templated ✅
    "active": true // Boolean - NOT templated ✅
  }
}
```

**Optional:** Allow key templating if explicitly enabled

```json
{
  "body_type": "template_json",
  "body_json": {
    "{{sku.0}}": ["screw", "rod"], // Key templating ⚠️
    "status": "SKU {{sku.0}} active" // Value templating ✅
  }
}
```

**Configuration:**

```elixir
use_cassette "test",
  template: [
    patterns: [sku: ~r/\d{4}-\d{4}/],
    allow_key_templates: true  # Default: false
  ]
```

### Text Bodies (`body_type: "template"`)

Templates can appear anywhere in the string:

```json
{
  "body_type": "template",
  "body": "SKU {{sku.0}} is active. Static text here. SKU {{sku.1}} pending."
}
```

### Rationale

- **JSON value templating** is safe and covers most use cases
- **JSON key templating** is powerful but riskier (can break JSON structure)
- **Text templating** is unrestricted for maximum flexibility

---

## Type Restrictions and Safety

Templates operate **only on string values** to ensure type safety and valid JSON
generation.

### String-Only Rule for JSON

When templating JSON bodies (`body_type: "template_json"`), template markers can
ONLY appear in string contexts, never in numbers, booleans, null, or other
types.

**Valid Examples:**

```json
{
  "sku": "{{sku.0}}", // ✅ String value
  "message": "SKU {{sku.0}} found", // ✅ Partial string template
  "{{sku.0}}": ["data"] // ✅ String key (if allow_key_templates: true)
}
```

**Invalid Examples:**

```json
{
  "count": {{number.0}},      // ❌ Number context - not a string!
  "active": {{bool.0}},       // ❌ Boolean context
  "value": null{{id.0}}       // ❌ Null context
}
```

### How Values Are Handled by Type

| JSON Type | Templatable?  | Example                               |
| --------- | ------------- | ------------------------------------- |
| String    | ✅ Yes        | `"SKU {{sku.0}}"`                     |
| Number    | ❌ No         | `5` (stays literal)                   |
| Boolean   | ❌ No         | `true` (stays literal)                |
| Null      | ❌ No         | `null` (stays literal)                |
| Array     | Children only | `["{{sku.0}}"]` (string element)      |
| Object    | Children only | `{"key": "{{sku.0}}"}` (string value) |

### Enforcement During Recording

```elixir
defmodule ReqCassette.Template.Replacer do
  @doc """
  Create JSON template by walking structure and only templating strings.
  """
  def create_json_template(json_data, variables, opts) do
    walk_json(json_data, fn value ->
      case value do
        # Only template string values
        str when is_binary(str) ->
          replace_in_string(str, variables, opts)

        # Never template these - keep as-is
        num when is_number(num) -> num
        bool when is_boolean(bool) -> bool
        nil -> nil

        # Walk children for arrays/maps
        other -> other
      end
    end)
  end
end
```

### Example Recording with Mixed Types

**Request:**

```
"Get details for SKU 1234-5678"
```

**Response (recorded):**

```json
{
  "sku": "1234-5678",
  "count": 5,
  "active": true,
  "price": 29.99,
  "notes": null,
  "message": "SKU 1234-5678 in stock"
}
```

**Response Template:**

```json
{
  "sku": "{{sku.0}}", // String → templated
  "count": 5, // Number → literal
  "active": true, // Boolean → literal
  "price": 29.99, // Number → literal
  "notes": null, // Null → literal
  "message": "SKU {{sku.0}} in stock" // String → templated
}
```

### Text Body Exception

For text bodies (`body_type: "template"`), there are no type restrictions since
the entire content is a string:

```
SKU {{sku.0}} has count 5 and is active
```

### Cassette Validation

When loading a cassette, validate that template markers only appear in valid
contexts:

```elixir
# Invalid cassette - reject during load
%{
  "body_type" => "template_json",
  "body_json" => %{"count" => "{{number.0}}"}  # OK - it's a string!
}

# This would be invalid (but can't represent in valid JSON anyway):
%{
  "body_type" => "template_json",
  "body_json" => %{"count" => {{number.0}}}  # ❌ Syntax error - not valid JSON
}
```

**Key insight:** The string-only restriction is naturally enforced by JSON
syntax - you can't write `{{marker}}` without quotes and have valid JSON.

### What If Non-String Values Are Dynamic?

**Problem:** What if the count changes between recordings?

```json
// Recording 1
{"sku": "1234-5678", "count": 5}

// Recording 2
{"sku": "9999-8888", "count": 10}
```

**Solution:** Use a different cassette. Templates handle **structural**
variation (same shape, different IDs), not **semantic** variation (different
data values).

**Alternative:** If the API can return the value as a string, it becomes
templatable:

```json
{
  "count_display": "5 items", // Can template the "5"
  "count_raw": 5 // Cannot template
}
```

### Rationale

- **Type safety** - Generated JSON is always valid
- **Simplicity** - No need to track/preserve types during extraction
- **Predictability** - Clear rules about what gets templated
- **Coverage** - 99% of dynamic values (IDs, SKUs, emails, dates) are strings
  anyway

---

## Debugging with Extraction Diff

When a template match fails during replay, ReqCassette shows a detailed diff to
help debug the issue.

### Example Error Message

```
Template match failed for cassette "sku_lookup"

Expected template structure:
  List SKU {{sku.0}} separated from SKU {{sku.1}}

Incoming request (templated):
  List SKU {{sku.0}} but exclude SKU {{sku.1}}
                     ^^^^^^^^^^^
                     Difference detected here

Extracted variables:
  sku.0 = "6785-9443"
  sku.1 = "3488-3234"

Hint: The request structure changed. Update cassette or adjust patterns.
```

### Information Provided

1. **Expected template** - The cassette's templated request
2. **Incoming template** - The current request converted to template form
3. **Diff highlighting** - Shows where structures differ
4. **Extracted variables** - Shows what values were extracted
5. **Hint** - Suggests next steps

### Implementation

```elixir
defmodule ReqCassette.Template.Debug do
  def format_diff(expected, actual, diff, vars) do
    """
    Template match failed

    Expected: #{expected}
    Actual:   #{actual}
    Diff:     #{highlight_diff(diff)}

    Extracted variables:
    #{format_variables(vars)}

    Hint: #{suggest_fix(diff)}
    """
  end

  defp format_variables(vars) do
    vars
    |> Enum.map(fn {name, values} ->
      values
      |> Enum.with_index()
      |> Enum.map(fn {val, idx} -> "  #{name}.#{idx} = #{inspect(val)}" end)
    end)
    |> List.flatten()
    |> Enum.join("\n")
  end
end
```

---

## Complete Flow Diagram

### Recording Flow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Request arrives                                          │
│    "List SKU 0234-3455 and SKU 0344-4456"                   │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. Apply filters (if configured)                            │
│    filter_request removes sensitive data                    │
│    Result: Filtered request (API keys removed, etc.)        │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. Normalize/sort data for predictable extraction           │
│    - Sort JSON object keys alphabetically                   │
│    - Sort query parameters alphabetically                   │
│    - Preserve array and path order                          │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. Extract patterns from request                            │
│    Scopes: URI path, query params, body                     │
│    Pattern: ~r/\d{4}-\d{4}/                                 │
│    Result: %{sku: ["0234-3455", "0344-4456"]}              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. Escape literal {{ }} in request/response                │
│    (Prevent collision with template markers)                │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. Create request template                                  │
│    "List SKU {{sku.0}} and SKU {{sku.1}}"                  │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. Perform actual HTTP request, get response                │
│    {"0234-3455": ["screw"], "other": 123}                  │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 8. Apply response filters (if configured)                   │
│    filter_response removes sensitive data from response     │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 9. Scan response for extracted values                       │
│    "0234-3455" → Found in response, template it             │
│    "0344-4456" → Not found, still template (wildcard)       │
│    "other-value" → Not extracted, keep literal              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 10. Create response template                                │
│     {"{{sku.0}}": ["screw"], "other": 123}                 │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 11. Save cassette                                           │
│     - Template metadata (patterns, recorded values)         │
│     - Templated request                                     │
│     - Templated response                                    │
└─────────────────────────────────────────────────────────────┘
```

### Replay Flow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Request arrives                                          │
│    "List SKU 6785-9443 and SKU 3488-3234"                   │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. Apply filters (if configured)                            │
│    filter_request removes sensitive data                    │
│    (Same filters as recording)                              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. Normalize/sort data for predictable extraction           │
│    - Sort JSON object keys alphabetically                   │
│    - Sort query parameters alphabetically                   │
│    - Preserve array and path order                          │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. Extract patterns (same patterns from cassette)           │
│    Scopes: URI path, query params, body                     │
│    Result: %{sku: ["6785-9443", "3488-3234"]}              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. Create templated version of incoming request             │
│    "List SKU {{sku.0}} and SKU {{sku.1}}"                  │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. Load cassette and attempt template matching              │
│    Incoming:  "List SKU {{sku.0}} and SKU {{sku.1}}"       │
│    Cassette:  "List SKU {{sku.0}} and SKU {{sku.1}}"       │
│    Match: ✅ → Continue to step 7                           │
│    Match: ❌ → Error (no matching interaction)              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. Substitute new values into response template             │
│    Template: {"{{sku.0}}": ["screw"], "other": 123}        │
│    Apply: {{sku.0}} → "6785-9443"                          │
│    Result: {"6785-9443": ["screw"], "other": 123}          │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 8. Unescape literal {{ }}                                   │
│    (Restore original escaped content)                       │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 9. Apply response filters (if configured)                   │
│    filter_response removes sensitive data from response     │
│    (Same filters as recording)                              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 10. Return response                                         │
└─────────────────────────────────────────────────────────────┘
```

---

## Cassette Format

**Key principle:** Templates are configured **per-interaction**, not
per-cassette. Each interaction can have its own template settings, or none at
all.

### Version Strategy

ReqCassette uses semantic versioning for cassette files:

- **Version 1.0** - Original format, JSON key order undefined
- **Version 2.0** - New format with sorted JSON + template support

**Backwards Compatibility Strategy:**

```elixir
# When loading cassettes:
case cassette.version do
  "1.0" ->
    # Sort JSON in memory during load
    # Works with both templated and non-templated matching
    sorted_interactions = Enum.map(cassette.interactions, fn interaction ->
      normalize_interaction_in_memory(interaction)
    end)

  "2.0" ->
    # Already sorted, use directly
    cassette.interactions
end

# When saving cassettes:
# Always save as v2.0 with sorted JSON
```

**Benefits:**

- ✅ **No migration required** - v1.0 files continue to work
- ✅ **Automatic upgrade** - Re-recording creates v2.0
- ✅ **Better matching** - Sorting helps even for non-template exact matching
- ✅ **Performance** - v2.0 avoids runtime sorting
- ✅ **Canonical format** - v2.0 files are diffable and git-friendly

**Why sorting helps non-template matching:**

Even without templates, sorted JSON improves exact matching:

```elixir
# Without sorting (v1.0 - fragile):
Recording: {"product": "widget", "count": 5}  # Hash order A
Replay:    {"count": 5, "product": "widget"}  # Hash order B
Match: ❌ Different string representation

# With sorting (v2.0 - robust):
Recording: {"count": 5, "product": "widget"}  # Sorted
Replay:    {"count": 5, "product": "widget"}  # Sorted
Match: ✅ Same canonical representation
```

### JSON Schema v2.0 with Templates

**Example: Mixed cassette with templated and non-templated interactions**

```json
{
  "version": "2.0",
  "interactions": [
    {
      "template": {
        "enabled": true,
        "patterns": {
          "sku": "\\d{4}-\\d{4}",
          "order_id": "ORD-\\d+"
        },
        "strategy": "positional",
        "recorded_values": {
          "sku": ["0234-3455", "0344-4456"],
          "order_id": ["ORD-12345"]
        },
        "config": {
          "allow_key_templates": false
        }
      },
      "request": {
        "method": "POST",
        "uri": "https://api.example.com/lookup",
        "body_type": "template",
        "body": "List SKU {{sku.0}} separated from SKU {{sku.1}}"
      },
      "response": {
        "status": 200,
        "body_type": "template_json",
        "body_json": {
          "{{sku.0}}": ["screw", "rod", "plate"],
          "obs": "SKU {{sku.0}} is inactive",
          "system_note": "Literal \\{\\{value\\}\\} here",
          "static_field": "0000-1111"
        }
      },
      "recorded_at": "2025-10-18T10:00:00Z"
    },
    {
      "template": null,
      "request": {
        "method": "GET",
        "uri": "https://api.example.com/health",
        "body": null
      },
      "response": {
        "status": 200,
        "body_type": "json",
        "body_json": {
          "status": "ok"
        }
      },
      "recorded_at": "2025-10-18T10:01:00Z"
    }
  ]
}
```

**Note:**
- Interaction 1 uses templates, Interaction 2 does not (flexible usage)
- Version 2.0 cassette format with sorted JSON keys
- All `body_json` fields have keys sorted alphabetically (recursively)

### Version 2.0 Changes from 1.0

**What's new in v2.0:**

1. **Sorted JSON Bodies**
   - All `body_json` fields stored with keys sorted alphabetically
   - Recursive sorting for nested objects
   - Arrays preserve original order (have semantic meaning)

2. **Template Support**
   - New `template` field per interaction
   - New body types: `"template"` and `"template_json"`

3. **Query Parameter Normalization**
   - Query strings stored in sorted order (if parsed)
   - More consistent matching

**What stays the same:**

- Basic interaction structure
- HTTP method, URI, headers, status
- Response bodies (just sorted if JSON)
- Recording and replay semantics

**Migration path:**

No explicit migration needed:
- v1.0 cassettes load and normalize in memory
- Re-recording automatically creates v2.0
- Both versions work in same test suite

### Template Metadata Fields

- **`enabled`** (boolean) - Whether templating is active for this interaction
- **`patterns`** (map) - Named regex patterns used for extraction
  - Key: pattern name (e.g., `"sku"`)
  - Value: regex pattern as string (e.g., `"\\d{4}-\\d{4}"`)
- **`strategy`** (string) - Matching strategy (currently `"positional"`)
  - Future: `"named"`, `"semantic"`
- **`recorded_values`** (map) - Original values extracted during recording
  - Used for debugging and migration
  - Key: pattern name
  - Value: array of extracted values
- **`config`** (map) - Template configuration options
  - `allow_key_templates`: Allow JSON key templating

### Body Types

- **`"template"`** - Text body with template markers
  - Stored in `body` field
  - Example: `"SKU {{sku.0}} is active"`

- **`"template_json"`** - JSON body with template markers
  - Stored in `body_json` field (native JSON object)
  - Example: `{"{{sku.0}}": ["data"], "key": "{{sku.1}}"}`

### Escape Sequences in Cassettes

Literal `{{` and `}}` are escaped:

```json
{
  "body": "Literal \\{\\{marker\\}\\} and template {{sku.0}}"
}
```

---

## Configuration API

### Basic Usage

```elixir
use ReqCassette

test "SKU lookup with templates" do
  use_cassette "sku_lookup",
    template: [
      patterns: [
        sku: ~r/\d{4}-\d{4}/
      ]
    ] do
    # First run: Records with "0234-3455"
    # Next run: Works with "6785-9443"
    response = Req.post!("https://api.example.com/lookup",
      body: "List SKU 0234-3455")

    assert response.status == 200
  end
end
```

### Configuration Options

```elixir
use_cassette "test",
  template: [
    # Pattern definitions (required)
    patterns: [
      sku: ~r/\d{4}-\d{4}/,
      order_id: ~r/ORD-\d+/,
      email: ~r/[\w\.-]+@[\w\.-]+/
    ],

    # Allow templating JSON keys (default: false)
    allow_key_templates: false,

    # Matching strategy (default: :positional, though it uses value-based indexing)
    strategy: :positional,

    # Future: Custom extraction callback
    # extract_fn: &MyModule.extract/1,

    # Future: Custom replacement callback
    # replace_fn: &MyModule.replace/2
  ] do
  # ...
end
```

### Pattern Definition

Patterns are named regex expressions:

```elixir
patterns: [
  # Simple pattern
  sku: ~r/\d{4}-\d{4}/,

  # Pattern with groups (entire match is used)
  order_id: ~r/ORD-\d+/,

  # Complex pattern
  iso_date: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
]
```

**Note:** The entire match is used as the template variable. Regex capture
groups are not used (may be added in future versions).

### Best Practices for Writing Patterns

**1. Be Specific, Not General**

```elixir
# ✅ Good: Specific pattern unlikely to match unintended values
patterns: [
  order_id: ~r/ORD-\d{6}/,              # Only matches "ORD-" + 6 digits
  sku: ~r/SKU-[A-Z]{2}-\d{4}/           # Only matches "SKU-XX-1234" format
]

# ❌ Bad: Overly broad patterns that match too much
patterns: [
  id: ~r/\d+/,                          # Matches ANY number (fragile!)
  code: ~r/[A-Z]+/                      # Matches ANY uppercase word
]
```

**Why:** Broad patterns extract unintended values, making instance markers
unpredictable. Specific patterns ensure `{{order_id.0}}` always refers to what
you expect.

**2. Use Anchors and Boundaries**

```elixir
# ✅ Good: Word boundaries prevent partial matches
patterns: [
  user_id: ~r/\bUSER-\d+\b/             # Won't match "POWER-USER-123"
]

# ❌ Bad: No boundaries, matches substrings
patterns: [
  user_id: ~r/USER-\d+/                 # Might match inside "POWER-USER-123"
]
```

**3. Avoid Greedy Patterns**

```elixir
# ✅ Good: Non-greedy, stops at first match
patterns: [
  session: ~r/session_[a-z0-9]{16}/    # Exactly 16 chars
]

# ❌ Bad: Greedy, might capture too much
patterns: [
  session: ~r/session_.+/              # Captures everything after "session_"
]
```

**4. Test Patterns Before Recording**

```elixir
# Test your pattern in IEx first
iex> content = "Order ORD-123456 and ORD-789012"
iex> Regex.scan(~r/ORD-\d{6}/, content)
[["ORD-123456"], ["ORD-789012"]]  # ✅ Good: Matches what you expect

iex> Regex.scan(~r/\d+/, content)
[["123456"], ["789012"]]          # ⚠️  Might also match other numbers!
```

**5. Document Expected Order**

When using positional markers, add a comment explaining the expected order:

```elixir
use_cassette "multi_order",
  template: [
    # Extracts in order: URI path, query params (sorted), body
    # {{order_id.0}} = primary order from path
    # {{order_id.1}} = reference order from query param "ref"
    # {{order_id.2}} = related order from body
    patterns: [order_id: ~r/ORD-\d+/]
  ]
```

**6. Prefer Specific Names Over Generic**

```elixir
# ✅ Good: Descriptive pattern names
patterns: [
  order_id: ~r/ORD-\d+/,
  invoice_id: ~r/INV-\d+/,
  tracking_number: ~r/TRACK-[A-Z0-9]+/
]

# ❌ Bad: Generic names that could overlap
patterns: [
  id: ~r/\w+-\d+/                      # What kind of ID?
]
```

**7. Consider Future Named Strategy**

While positional markers work, design patterns with future named extraction in
mind:

```elixir
# Current positional strategy
patterns: [primary_order: ~r/ORD-\d+/]
# Becomes: {{primary_order.0}}, {{primary_order.1}}, ...

# Future named strategy (not yet implemented)
# Would become: {{primary_order}}, {{secondary_order}}, ...
```

**8. Combine with Filters for Safety**

Always filter sensitive data BEFORE template extraction:

```elixir
use_cassette "api_test",
  filter_request: fn req ->
    # Remove API key first (it might match a broad pattern!)
    remove_sensitive_fields(req)
  end,
  template: [
    patterns: [order_id: ~r/ORD-\d+/]
  ]
```

### Common Pattern Examples

```elixir
patterns: [
  # IDs and codes
  uuid: ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/,
  sku: ~r/SKU-\d{4}-\d{4}/,
  order_id: ~r/ORD-\d{6}/,

  # Dates and times
  iso_date: ~r/\d{4}-\d{2}-\d{2}/,
  iso_datetime: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/,

  # Contact info (be careful with PII!)
  email: ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/,

  # Custom formats
  tracking: ~r/[A-Z]{2}\d{9}[A-Z]{2}/,  # e.g., "AB123456789CD"
  reference: ~r/REF-[A-Z0-9]{8}/
]
```

---

## Implementation Plan

### Phase 1: Core Template Engine

**Files to create:**

```
lib/req_cassette/template/
├── extractor.ex      # Extract variables from request/response
├── replacer.ex       # Create and apply templates
├── matcher.ex        # Match templated requests
├── escape.ex         # Escape/unescape literals
├── normalizer.ex     # Normalize/sort JSON and params for predictable extraction
└── debug.ex          # Diff formatting for errors
```

**Key modules:**

#### `ReqCassette.Template.Extractor`

```elixir
defmodule ReqCassette.Template.Extractor do
  @doc """
  Extract variables from content based on patterns.

  ## Examples

      iex> patterns = %{sku: ~r/\d{4}-\d{4}/}
      iex> content = "SKU 0234-3455 and 0344-4456"
      iex> extract(content, patterns)
      %{sku: ["0234-3455", "0344-4456"]}
  """
  def extract(content, patterns)

  @doc """
  Scan response for request variables to determine which should be templated.

  Returns a MapSet of variable references (e.g., "sku.0", "sku.1") found in response.
  """
  def scan_response(response, variables)
end
```

#### `ReqCassette.Template.Replacer`

```elixir
defmodule ReqCassette.Template.Replacer do
  @doc """
  Create template by replacing values with markers.

  For JSON bodies, only string values are templated (numbers, booleans, null stay literal).
  For text bodies, templates can appear anywhere.

  Options:
  - scope: :request_only | :response_only | MapSet (which vars to template)
  - allow_key_templates: boolean (for JSON, template keys in addition to values)
  - body_type: :json | :text (determines type checking behavior)
  """
  def create_template(content, variables, opts \\ [])

  @doc """
  Create JSON template by walking structure and only templating strings.

  Enforces type safety by skipping non-string values.
  """
  def create_json_template(json_data, variables, opts) do
    walk_json(json_data, fn value ->
      case value do
        # Only template string values
        str when is_binary(str) ->
          replace_in_string(str, variables, opts)

        # Never template these - preserve type
        num when is_number(num) -> num
        bool when is_boolean(bool) -> bool
        nil -> nil

        # Recursively handle collections
        list when is_list(list) -> Enum.map(list, &walk_json(&1, fn v -> v end))
        map when is_map(map) -> Map.new(map, fn {k, v} -> {k, walk_json(v, fn x -> x end)} end)
      end
    end)
  end

  @doc """
  Apply variables to template, replacing markers with actual values.

  Preserves JSON types - only replaces within strings.
  """
  def apply_template(template, variables)
end
```

#### `ReqCassette.Template.Matcher`

```elixir
defmodule ReqCassette.Template.Matcher do
  @doc """
  Match incoming templated request against cassette template.

  Returns {:ok, :match} or {:error, diff}
  """
  def match?(cassette_template, incoming_template)
end
```

#### `ReqCassette.Template.Escape`

```elixir
defmodule ReqCassette.Template.Escape do
  @doc "Escape literal {{ and }} in content"
  def escape(string)

  @doc "Unescape literal {{ and }}"
  def unescape(string)
end
```

#### `ReqCassette.Template.Debug`

```elixir
defmodule ReqCassette.Template.Debug do
  @doc "Format template match failure with diff and variable info"
  def format_diff(expected, actual, diff, variables)
end
```

---

### Phase 1.5: Cassette Version Loading

**Add to cassette loading logic:**

```elixir
defmodule ReqCassette.Cassette do
  @doc """
  Load cassette from disk and normalize based on version.
  """
  def load(path) do
    cassette = Jason.decode!(File.read!(path))

    case cassette["version"] do
      # v1.0: Normalize in memory
      "1.0" ->
        interactions = Enum.map(cassette["interactions"], fn interaction ->
          normalize_v1_interaction(interaction)
        end)
        %{cassette | "interactions" => interactions, "_loaded_version" => "1.0"}

      # v2.0: Already normalized
      "2.0" ->
        %{cassette | "_loaded_version" => "2.0"}

      # Default to v1.0 if version missing
      nil ->
        interactions = Enum.map(cassette["interactions"], fn interaction ->
          normalize_v1_interaction(interaction)
        end)
        %{cassette | "interactions" => interactions, "_loaded_version" => "1.0"}
    end
  end

  defp normalize_v1_interaction(interaction) do
    # Sort JSON bodies in memory
    request = if interaction["request"]["body_json"] do
      body_json = sort_json_keys(interaction["request"]["body_json"])
      put_in(interaction, ["request", "body_json"], body_json)
    else
      interaction
    end

    response = if interaction["response"]["body_json"] do
      body_json = sort_json_keys(interaction["response"]["body_json"])
      put_in(request, ["response", "body_json"], body_json)
    else
      request
    end

    response
  end

  defp sort_json_keys(data) when is_map(data) do
    data
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, value} -> {key, sort_json_keys(value)} end)
    |> Map.new()
  end

  defp sort_json_keys(data) when is_list(data) do
    # Preserve array order, but recurse into elements
    Enum.map(data, &sort_json_keys/1)
  end

  defp sort_json_keys(data), do: data

  @doc """
  Save cassette to disk - always as v2.0.
  """
  def save(cassette, path) do
    # Ensure all JSON is sorted before saving
    cassette_v2 = %{cassette | "version" => "2.0"}
    json = Jason.encode!(cassette_v2, pretty: true)
    File.write!(path, json)
  end
end
```

---

### Phase 2: Integration with ReqCassette.Plug

**Modify `lib/req_cassette/plug.ex`:**

**Note:** Templates work with `:record` and `:replay` modes only. Other modes
(`:record_once`, etc.) ignore template configuration.

**Note:** All cassette saving uses v2.0 format with sorted JSON.

#### Recording Path (`:record` mode)

```elixir
# After receiving response from network
if opts[:template] do
  # 0. Filters already applied before this point (filter_request, filter_response)

  # 1. Normalize request for extraction
  normalized_request = Template.Normalizer.normalize(request)
  # - Sorts JSON object keys alphabetically
  # - Sorts query parameters alphabetically
  # - Preserves array and path order

  # 2. Extract variables from request
  # Scopes: URI path, query params, body (NOT headers)
  variables = Template.Extractor.extract(
    normalized_request,
    opts[:template][:patterns]
  )

  # 3. Create templated request
  templated_request = Template.Replacer.create_template(
    normalized_request,
    variables,
    scope: :request_only
  )

  # 4. Normalize response for extraction
  normalized_response = Template.Normalizer.normalize(response)

  # 5. Scan response for variables
  response_vars = Template.Extractor.scan_response(normalized_response, variables)

  # 6. Create templated response
  templated_response = Template.Replacer.create_template(
    normalized_response,
    variables,
    scope: response_vars,
    allow_key_templates: opts[:template][:allow_key_templates]
  )

  # 7. Build interaction with template metadata
  interaction = %{
    template: %{
      enabled: true,
      patterns: normalize_patterns(opts[:template][:patterns]),
      strategy: opts[:template][:strategy] || :positional,
      recorded_values: variables,
      config: %{
        allow_key_templates: opts[:template][:allow_key_templates] || false
      }
    },
    request: templated_request,
    response: templated_response
  }
end
```

#### Replay Path (`:replay` mode)

```elixir
# Before matching cassette interaction
if interaction.template && interaction.template.enabled do
  # 0. Filters already applied before this point (filter_request)

  # 1. Normalize incoming request
  normalized_request = Template.Normalizer.normalize(request)

  # 2. Extract variables from incoming request
  # Scopes: URI path, query params, body (NOT headers)
  incoming_vars = Template.Extractor.extract(
    normalized_request,
    denormalize_patterns(interaction.template.patterns)
  )

  # 3. Create templated version of incoming request
  templated_incoming = Template.Replacer.create_template(
    normalized_request,
    incoming_vars,
    scope: :request_only
  )

  # 4. Match against cassette template
  case Template.Matcher.match?(interaction.request, templated_incoming) do
    :match ->
      # 5. Apply variables to response template
      response = Template.Replacer.apply_template(
        interaction.response,
        incoming_vars
      )
      {:ok, response}

    {:error, diff} ->
      # Template matching failed - show error
      error = Template.Debug.format_diff(
        interaction.request,
        templated_incoming,
        diff,
        incoming_vars
      )
      raise Template.MatchError, """
      Template matching failed:
      #{error}

      Hint: Request structure changed. Update cassette or adjust patterns.
      """
  end
end
```

**New module needed:**

#### `ReqCassette.Template.Normalizer`

```elixir
defmodule ReqCassette.Template.Normalizer do
  @doc """
  Normalize request/response for predictable extraction.

  - Sort JSON object keys alphabetically (recursive)
  - Sort query parameters alphabetically
  - Preserve array order (arrays have semantic ordering)
  - Preserve URI path order (paths have semantic ordering)
  """
  def normalize(data)
end
```

---

### Phase 3: Configuration API

**Update `lib/req_cassette.ex`:**

```elixir
defmodule ReqCassette do
  # ... existing code ...

  defmacro use_cassette(name, opts \\ [], do: block) do
    quote do
      opts = unquote(opts)

      # Extract template configuration
      template_opts = if opts[:template] do
        %{
          patterns: validate_patterns!(opts[:template][:patterns]),
          allow_key_templates: opts[:template][:allow_key_templates] || false,
          strategy: opts[:template][:strategy] || :positional
        }
      end

      # Pass to plug via cassette_info
      cassette_info = %{
        name: unquote(name),
        template: template_opts,
        # ... other options ...
      }

      # ... rest of macro ...
    end
  end

  defp validate_patterns!(patterns) do
    unless is_list(patterns) and Keyword.keyword?(patterns) do
      raise ArgumentError, "template patterns must be a keyword list"
    end

    Enum.each(patterns, fn {name, pattern} ->
      unless is_atom(name) and Regex.regex?(pattern) do
        raise ArgumentError,
          "pattern #{inspect(name)} must be a Regex, got: #{inspect(pattern)}"
      end
    end)

    patterns
  end
end
```

---

### Phase 4: Testing

**Test files:**

```
test/req_cassette/template/
├── extractor_test.exs       # Variable extraction
├── replacer_test.exs        # Template creation/application
├── matcher_test.exs         # Template matching
├── escape_test.exs          # Escape sequences
├── integration_test.exs     # End-to-end with cassettes
└── edge_cases_test.exs      # Collisions, nested, etc.
```

**Key test cases:**

- Extract single pattern with multiple matches
- Extract multiple different patterns
- Template with escape sequences (literal `{{}}`)
- Template JSON values only vs keys + values
- Match success with identical templates
- Match failure with diff output
- Response-only values stay literal
- Request-only values become wildcards
- Variables appearing in both request and response
- Empty extraction (pattern matches nothing)
- Duplicate values in same request
- Pattern overlap (multiple patterns match same text)

---

### Phase 5: Documentation

**Create guide:**

```
docs/guides/templating.md
```

**Content:**

- What are templates and when to use them
- Quick start example
- Pattern syntax and examples
- Escape sequences
- Debugging failed matches
- JSON vs text templating
- Best practices and limitations
- Common patterns (IDs, SKUs, emails, dates)
- LLM API integration examples

**Update existing docs:**

- `README.md` - Add templates section
- `lib/req_cassette.ex` - Document `:template` option
- `docs/DESIGN_SPEC.md` - Reference template design

---

## Edge Cases

### 1. Duplicate Values

**Scenario:** Same value extracted multiple times

```
Request: "SKU 1234-5678 and SKU 1234-5678 again"
Pattern: ~r/\d{4}-\d{4}/
```

**Decision:** Extract all occurrences, but assign same instance ID to duplicates

**Result during extraction:** `["1234-5678", "1234-5678"]` (preserves all matches)

**Result in template:** `"SKU {{sku.0}} and SKU {{sku.0}} again"`

**Rationale:** Instance-based indexing means identical values get the same marker.
The `.N` suffix is a unique value identifier, not a position counter. This allows
the same value to appear multiple times in different positions while maintaining
a single source of truth for that value during replay.

---

### 2. Nested Templates

**Scenario:** Template marker inside template marker

```
"Value is {{sku.{{index}}}}"
```

**Decision:** Not supported, single-level only

**Behavior:** Raise error during template creation if nested markers detected

**Rationale:** Adds complexity without clear benefit. Can be added in future if
needed.

---

### 3. Pattern Overlap

**Scenario:** Multiple patterns match same text

```elixir
patterns: [
  id: ~r/\d+/,
  sku: ~r/\d{4}-\d{4}/
]

content: "SKU 1234-5678"
```

**Decision:** Most specific pattern wins (longest match)

**Result:** `%{sku: ["1234-5678"]}` (not `%{id: ["1234", "5678"]}`)

**Rationale:** Prefer specificity. Users can control by pattern order or
explicit capturing.

---

### 4. Empty Extraction

**Scenario:** Pattern matches but extracts empty string

```elixir
# Pattern using \w* can match empty strings
pattern: ~r/\w*/
content: "hello world"
# Would match: ["hello", "", "world", "", ...]
```

**Decision:** Skip empty extractions, don't create template variables

**Result:** `["hello", "world"]` (empty matches filtered out)

**Rationale:** Empty values are not useful for templating and can cause
confusion.

**Note:** Patterns use full matches, not capture groups. To avoid matching
empty values, use `+` instead of `*` (e.g., `~r/\w+/` instead of `~r/\w*/`).

---

### 5. Value Order Independence

**Scenario:** Same unique values extracted in different order during replay

```
Recording: "SKU 0234-3455 then SKU 0344-4456"
  → Template: "SKU {{sku.0}} then SKU {{sku.1}}"

Replay: "SKU 0344-4456 then SKU 0234-3455"
  → Template: "SKU {{sku.0}} then SKU {{sku.1}}"
  → Values: ["0344-4456", "0234-3455"]
```

**Decision:** Templates match because structure is identical

**Behavior:** Template structures match! During substitution:
- Recording: sku.0 → "0234-3455", sku.1 → "0344-4456"
- Replay: sku.0 → "0344-4456", sku.1 → "0234-3455"

**Rationale:** Instance-based indexing with structural matching means the same
set of unique values can appear in any order/position. The `.N` indices map to
whichever unique values are present, maintaining template structure while allowing
value flexibility.

---

### 6. Pattern in Response Only

**Scenario:** Value matches pattern but only appears in response

```
Request: "Get system info"
Response: {"system_sku": "1234-5678"}
```

**Decision:** Keep as literal value, don't template

**Rationale:** Not parameterized by request, it's static API data

---

### 7. Special Characters in Values

**Scenario:** Extracted value contains regex special chars

```
Pattern: ~r/version: [\d.]+/
Content: "version: 1.2.3"
Extracted: "version: 1.2.3"
```

**Decision:** Escape the value when creating template

**Implementation:** Use `Regex.escape/1` on extracted values before replacement

**Rationale:** Prevent regex interpretation during substitution

---

### 8. Multiline Patterns

**Scenario:** Pattern spans multiple lines

```
content: """
SKU: 1234-5678
DESC: Widget
"""

pattern: ~r/SKU: \d{4}-\d{4}\nDESC: \w+/
```

**Decision:** Support multiline patterns with proper escaping

**Rationale:** Some APIs use multiline formats (YAML, etc.)

---

### 9. Case Sensitivity

**Scenario:** Same value with different casing

```
Request: "User Alice and ALICE"
Pattern: ~r/\b[A-Z][a-z]+\b/
```

**Decision:** Extract both as separate values

**Result:** `%{user: ["Alice", "ALICE"]}`

**Rationale:** Different case = different values. User can use case-insensitive
patterns if needed: `~r/alice/i`

---

### 10. Binary/Non-Text Bodies

**Scenario:** Request/response body is binary (image, PDF, etc.)

**Decision:** Templates only work with text-based bodies

**Behavior:** Skip templating for `body_type: "blob"`

**Rationale:** Pattern matching on binary data is complex and uncommon. Can be
added later if needed.

---

### 11. Dynamic Non-String Values

**Scenario:** Response contains dynamic numbers, booleans, or null values

```
Recording 1:
  Request:  "Get SKU 1234-5678"
  Response: {"sku": "1234-5678", "count": 5, "active": true}

Recording 2:
  Request:  "Get SKU 9999-8888"
  Response: {"sku": "9999-8888", "count": 10, "active": false}
```

**Decision:** Templates cannot handle dynamic non-string values

**Behavior:** Numbers, booleans, null are never templated. If they vary, you
need separate cassettes.

**Template result:**

```json
{
  "sku": "{{sku.0}}", // ✅ Templated
  "count": 5, // ❌ Literal - won't match if count changes
  "active": true // ❌ Literal - won't match if active changes
}
```

**Workaround:** If the API can return values as strings, they become
templatable:

```json
{
  "count_display": "5 items", // ✅ Can template
  "active_display": "true", // ✅ Can template
  "count_raw": 5, // ❌ Cannot template
  "active_raw": true // ❌ Cannot template
}
```

**Rationale:** Templates are for **structural** variation (same shape, different
IDs/codes), not **semantic** variation (different business data). Type safety is
more important than universal flexibility.

---

### 12. Parameter and JSON Ordering

**Scenario:** JSON keys or query parameters arrive in different orders

**Without normalization (would break):**

```elixir
# Recording
Request: {"product": "SKU-1234", "category": "tools"}
Query: ?filter=active&sort=name
Extraction order: ["SKU-1234"]  # Depends on hash map iteration order
Template: {{sku.0}} = "SKU-1234"

# Replay - Same data, different order
Request: {"category": "tools", "product": "SKU-5678"}
Query: ?sort=name&filter=active
Extraction order: Could differ without sorting!
Template: {{sku.0}} = might not match the same field
```

**With normalization (robust):**

```elixir
# Recording
1. Normalize: Sort JSON keys and query params
   Request: {"category": "tools", "product": "SKU-1234"}
   Query: ?filter=active&sort=name
2. Extract in sorted order
   Extracted: ["SKU-1234"]
   Template: {{sku.0}} = "SKU-1234"

# Replay
1. Normalize: Sort JSON keys and query params
   Request: {"category": "tools", "product": "SKU-5678"}
   Query: ?filter=active&sort=name
2. Extract in same sorted order
   Extracted: ["SKU-5678"]
   Template: {{sku.0}} = "SKU-5678" ✅ Matches!
```

**Decision:** Always normalize before extraction

**Implementation:**

- Sort JSON object keys alphabetically (recursive)
- Sort query parameters alphabetically by key
- Preserve array element order (semantic)
- Preserve URI path segment order (semantic)

**Rationale:**

- JSON objects are unordered - key iteration order is implementation-dependent
- Query parameter order is arbitrary in HTTP spec
- Sorting ensures predictable positional indexing
- Reduces false template match failures

**Best practice:** Even with sorting, write specific patterns to avoid relying
too heavily on positional order.

---

## Future Enhancements

### Named Template Strategy

Instead of positional (`{{sku.0}}`), use semantic names:

```elixir
template: [
  extract: [
    {:primary_sku, ~r/primary SKU (\d{4}-\d{4})/},
    {:secondary_sku, ~r/secondary SKU (\d{4}-\d{4})/}
  ]
]

# Template: "{{primary_sku}} vs {{secondary_sku}}"
```

**Benefits:** Handles order changes, more readable

---

### Custom Extraction Callbacks

Allow user-defined extraction logic:

```elixir
template: [
  extract_fn: fn request ->
    # Custom extraction logic
    skus = extract_skus_from_json(request.body)
    %{primary: List.first(skus), others: Enum.drop(skus, 1)}
  end
]
```

**Benefits:** Maximum flexibility for complex cases

---

### JSONPath Patterns

Use JSONPath for structured extraction:

```elixir
template: [
  json_paths: [
    user_id: "$.user.id",
    transaction_id: "$.transaction.ref"
  ]
]
```

**Benefits:** Precise extraction from JSON structures

---

### Template Inheritance

Share templates across cassettes:

```elixir
# Define once
ReqCassette.Config.template(:sku_pattern,
  patterns: [sku: ~r/\d{4}-\d{4}/]
)

# Use everywhere
use_cassette "test1", template: :sku_pattern
use_cassette "test2", template: :sku_pattern
```

**Benefits:** DRY, consistent patterns across test suite

---

## Summary

Templates enable powerful parameterized cassettes by:

1. **Extracting** dynamic values from requests using patterns
2. **Templating** both request and response with markers
3. **Matching** on template structure (not values) during replay
4. **Substituting** new values into response template

Key design decisions:

- **Escape sequences** prevent collision with literal `{{`
- **Variable rules** determine what gets templated (request-only, both, etc.)
- **Partial templates** mix static and dynamic content
- **Debug diff** helps troubleshoot match failures
- **Positional strategy** is simple and covers most use cases

This design balances power and simplicity, enabling significant cassette reuse
while maintaining safety and debuggability.
