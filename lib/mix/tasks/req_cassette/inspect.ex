defmodule Mix.Tasks.ReqCassette.Inspect do
  @moduledoc """
  Inspects ReqCassette cassette files and displays template information.

  This task is useful for:
  - Verifying templates were applied correctly after recording
  - Understanding what variables were extracted and where they appear
  - Debugging template matching issues

  ## Usage

      $ mix req_cassette.inspect path/to/cassette.json
      $ mix req_cassette.inspect cassette1.json cassette2.json

  ## Options

    * `--verbose`, `-v` - Show full request/response bodies
    * `--json`, `-j` - Output as JSON for programmatic use

  ## Examples

      # Basic inspection
      $ mix req_cassette.inspect test/cassettes/llm_chat.json

      Cassette: test/cassettes/llm_chat.json
      Version: 2.0
      Interactions: 2

      Interaction #1 (recorded: 2025-01-15T10:30:00Z)
        Template: ENABLED
        Patterns: msg_id, toolu_id
        Recorded Values:
          msg_id.0 = "msg_01XzW7o3s58J6KauMpLBFtEf"
          toolu_id.0 = "toolu_01K6u2Q9D6W7heeVvKAcLcAJ"
        Request: POST https://api.anthropic.com/v1/messages
        Response: 200 OK

      # JSON output for scripting
      $ mix req_cassette.inspect --json test/cassettes/llm_chat.json | jq '.interactions[0].recorded_values'

  """

  use Mix.Task

  alias ReqCassette.Cassette

  @shortdoc "Inspect ReqCassette cassette files"

  @switches [
    verbose: :boolean,
    json: :boolean
  ]
  @aliases [
    v: :verbose,
    j: :json
  ]

  @impl Mix.Task
  def run(args) do
    {opts, paths, _} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if paths == [] do
      Mix.shell().error(
        "Usage: mix req_cassette.inspect [options] <cassette_path> [<cassette_path>...]"
      )

      Mix.shell().error("")
      Mix.shell().error("Options:")
      Mix.shell().error("  --verbose, -v    Show full request/response bodies")
      Mix.shell().error("  --json, -j       Output as JSON")
      exit({:shutdown, 1})
    end

    results =
      Enum.map(paths, fn path ->
        case Cassette.load(path) do
          {:ok, cassette} ->
            {:ok, path, cassette}

          :not_found ->
            {:error, path, "File not found"}
        end
      end)

    if opts[:json] do
      output_json(results, opts)
    else
      output_text(results, opts)
    end
  end

  defp output_text(results, opts) do
    Enum.each(results, fn result ->
      case result do
        {:ok, path, cassette} ->
          Mix.shell().info(format_cassette_text(cassette, path, opts))

        {:error, path, reason} ->
          Mix.shell().error("Error: #{path} - #{reason}")
      end
    end)
  end

  defp output_json(results, opts) do
    json_output =
      Enum.map(results, fn result ->
        case result do
          {:ok, path, cassette} ->
            format_cassette_json(cassette, path, opts)

          {:error, path, reason} ->
            %{path: path, error: reason}
        end
      end)

    output =
      if length(json_output) == 1 do
        hd(json_output)
      else
        json_output
      end

    Mix.shell().info(Jason.encode!(output, pretty: true))
  end

  defp format_cassette_text(cassette, path, opts) do
    interactions = cassette["interactions"] || []
    version = cassette["version"] || "unknown"

    header = """
    Cassette: #{path}
    Version: #{version}
    Interactions: #{length(interactions)}
    """

    interaction_details =
      interactions
      |> Enum.with_index(1)
      |> Enum.map(fn {interaction, idx} ->
        format_interaction_text(interaction, idx, opts)
      end)
      |> Enum.join("\n")

    header <> "\n" <> interaction_details
  end

  defp format_interaction_text(interaction, index, opts) do
    recorded_at = interaction["recorded_at"] || "unknown"
    request = interaction["request"] || %{}
    response = interaction["response"] || %{}
    template = interaction["template"]

    template_section =
      if template && template["enabled"] do
        patterns = template["patterns"] || %{}
        values = template["recorded_values"] || %{}

        pattern_names =
          patterns
          |> Map.keys()
          |> Enum.sort()
          |> Enum.join(", ")

        value_lines = format_recorded_values(values)

        """
          Template: ENABLED
          Patterns: #{pattern_names}
          Recorded Values:
        #{value_lines}
        """
      else
        "  Template: DISABLED\n"
      end

    request_summary = "  Request: #{request["method"] || "?"} #{request["uri"] || "?"}"
    response_summary = "  Response: #{response["status"] || "?"}"

    body_details =
      if opts[:verbose] do
        "\n" <> format_verbose_bodies(request, response)
      else
        ""
      end

    """
    Interaction ##{index} (recorded: #{recorded_at})
    #{String.duplicate("-", 50)}
    #{template_section}
    #{request_summary}
    #{response_summary}#{body_details}
    """
  end

  defp format_recorded_values(values) when map_size(values) == 0 do
    "    (none)"
  end

  defp format_recorded_values(values) do
    values
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.flat_map(fn {name, vals} ->
      vals
      |> Enum.with_index()
      |> Enum.map(fn {val, idx} ->
        "    #{name}.#{idx} = #{inspect(val)}"
      end)
    end)
    |> Enum.join("\n")
  end

  defp format_verbose_bodies(request, response) do
    request_body = format_body_verbose(request)
    response_body = format_body_verbose(response)

    """
      Request Body:
    #{indent(request_body, 4)}

      Response Body:
    #{indent(response_body, 4)}
    """
  end

  defp format_body_verbose(data) do
    cond do
      Map.has_key?(data, "body_json") ->
        Jason.encode!(data["body_json"], pretty: true)

      Map.has_key?(data, "body") and data["body"] != "" ->
        data["body"]

      Map.has_key?(data, "body_blob") ->
        size = byte_size(Base.decode64!(data["body_blob"]))
        "(binary data, #{size} bytes)"

      true ->
        "(empty)"
    end
  end

  defp indent(text, spaces) do
    prefix = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map(&"#{prefix}#{&1}")
    |> Enum.join("\n")
  end

  defp format_cassette_json(cassette, path, opts) do
    interactions = cassette["interactions"] || []

    %{
      path: path,
      version: cassette["version"],
      interaction_count: length(interactions),
      interactions:
        Enum.map(interactions, fn interaction ->
          format_interaction_json(interaction, opts)
        end)
    }
  end

  defp format_interaction_json(interaction, opts) do
    template = interaction["template"]
    request = interaction["request"] || %{}
    response = interaction["response"] || %{}

    base = %{
      recorded_at: interaction["recorded_at"],
      template_enabled: template && template["enabled"],
      patterns: template && Map.keys(template["patterns"] || %{}),
      recorded_values: template && template["recorded_values"],
      request: %{
        method: request["method"],
        uri: request["uri"],
        query_string: request["query_string"]
      },
      response: %{
        status: response["status"]
      }
    }

    if opts[:verbose] do
      Map.merge(base, %{
        request_body: extract_body(request),
        response_body: extract_body(response)
      })
    else
      base
    end
  end

  defp extract_body(data) do
    cond do
      Map.has_key?(data, "body_json") -> data["body_json"]
      Map.has_key?(data, "body") -> data["body"]
      Map.has_key?(data, "body_blob") -> "(binary)"
      true -> nil
    end
  end
end
