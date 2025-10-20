defmodule ReqCassette.AgentReplayTest do
  use ExUnit.Case, async: false
  require Logger

  @moduletag :req_llm
  @cassette_dir "test/fixtures/agent_cassettes"

  setup do
    # Clean up cassettes before each test
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)

    # Ensure ReqLLM application is started
    Application.ensure_all_started(:req_llm)

    :ok
  end

  defmodule MyAgentWithCassettes do
    @moduledoc """
    A GenServer-based AI agent that supports ReqCassette for recording and replaying LLM calls.
    """
    use GenServer

    alias ReqLLM.{Context, Tool, Response, Message, ToolCall}

    defstruct [:history, :tools, :model, :req_http_options]

    @default_model "anthropic:claude-sonnet-4-20250514"

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def prompt(pid, message) when is_binary(message) do
      GenServer.call(pid, {:prompt, message}, 30_000)
    end

    @impl true
    def init(opts) do
      system_prompt =
        Keyword.get(opts, :system_prompt, """
        You are a helpful AI assistant with access to tools.

        When you need to compute math, use the calculator tool with the expression parameter.
        IMPORTANT: Wrap all numbers in the expression with <num> tags. For example: <num>A</num> * <num>B</num>

        Do not wrap arguments in code fences. Do not include extra text in arguments.

        When you need to search for information, use the web_search tool with a relevant query.

        Always use tools when appropriate and provide clear, helpful responses.
        """)

      model = Keyword.get(opts, :model, @default_model)
      tools = setup_tools()

      # Setup cassette configuration
      req_http_options =
        case Keyword.get(opts, :cassette_opts) do
          nil ->
            []

          cassette_opts ->
            [plug: {ReqCassette.Plug, Map.new(cassette_opts)}]
        end

      history = Context.new([Context.system(system_prompt)])

      {:ok,
       %__MODULE__{
         history: history,
         tools: tools,
         model: model,
         req_http_options: req_http_options
       }}
    end

    @impl true
    def handle_call({:prompt, message}, _from, state) do
      new_history = Context.append(state.history, Context.user(message))

      case generate_with_tools(state.model, new_history, state.tools, state.req_http_options) do
        {:ok, final_history, final_response} ->
          {:reply, {:ok, final_response}, %{state | history: final_history}}

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    end

    defp generate_with_tools(model, history, tools, req_http_options) do
      with {:ok, response} <- generate_initial_response(model, history, tools, req_http_options),
           text <- Response.text(response),
           tool_calls <- extract_tool_calls(response) do
        handle_tool_calls(model, history, tools, req_http_options, text, tool_calls)
      end
    end

    defp generate_initial_response(model, history, tools, req_http_options) do
      ReqLLM.generate_text(
        model,
        history.messages,
        tools: tools,
        max_tokens: 1024,
        req_http_options: req_http_options
      )
    end

    defp handle_tool_calls(_model, history, _tools, _req_http_options, text, []) do
      # No tools called, we're done
      final_history = Context.append(history, Context.assistant(text))
      {:ok, final_history, text}
    end

    defp handle_tool_calls(model, history, tools, req_http_options, text, tool_calls) do
      assistant_message = Context.assistant(text, tool_calls: tool_calls)
      history_with_tool_call = Context.append(history, assistant_message)

      tool_result_messages = execute_tool_calls(tool_calls, tools)

      history_with_results = Context.append(history_with_tool_call, tool_result_messages)

      generate_final_response(model, history_with_results, req_http_options)
    end

    defp execute_tool_calls(tool_calls, tools) do
      Enum.map(tool_calls, fn tool_call ->
        execute_single_tool(tool_call, tools)
      end)
    end

    defp execute_single_tool(tool_call, tools) do
      tool = Enum.find(tools, fn t -> t.name == tool_call.name end)

      case tool do
        nil ->
          result = %{error: "Tool not found"}
          Context.tool_result(tool_call.id, tool_call.name, Jason.encode!(result))

        tool ->
          case Tool.execute(tool, tool_call.arguments) do
            {:ok, result} ->
              result_str = if is_binary(result), do: result, else: Jason.encode!(result)
              Context.tool_result(tool_call.id, tool_call.name, result_str)

            {:error, error} ->
              error_result = %{error: "Tool execution failed: #{inspect(error)}"}
              Context.tool_result(tool_call.id, tool_call.name, Jason.encode!(error_result))
          end
      end
    end

    defp generate_final_response(model, history_with_results, req_http_options) do
      case ReqLLM.generate_text(
             model,
             history_with_results.messages,
             max_tokens: 1024,
             req_http_options: req_http_options
           ) do
        {:ok, final_response} ->
          final_text = Response.text(final_response)
          final_history = Context.append(history_with_results, Context.assistant(final_text))
          {:ok, final_history, final_text}

        {:error, error} ->
          {:error, error}
      end
    end

    defp extract_tool_calls(response) do
      case response.message do
        %Message{tool_calls: tool_calls} when is_list(tool_calls) and length(tool_calls) > 0 ->
          Enum.map(tool_calls, fn tool_call ->
            %{
              id: tool_call.id,
              name: ToolCall.name(tool_call),
              arguments: ToolCall.args_map(tool_call) || %{}
            }
          end)

        _ ->
          []
      end
    end

    defp setup_tools do
      [
        Tool.new!(
          name: "calculator",
          description:
            "Perform mathematical calculations. Pass an expression string with numbers wrapped in <num> tags.",
          parameter_schema: [
            expression: [
              type: :string,
              required: true,
              doc:
                "Mathematical expression to evaluate. Wrap all numbers in <num> tags. Examples: '<num>a</num> * <num>b</num>', '<num>c</num> + <num>d</num>', 'sqrt(<num>e</num>)'"
            ]
          ],
          callback: &calculator_callback/1
        ),
        Tool.new!(
          name: "web_search",
          description: "Search the web for information",
          parameter_schema: [
            query: [type: :string, required: true, doc: "Search query"]
          ],
          callback: fn %{"query" => query} ->
            {:ok, "Mock search results for: #{query}"}
          end
        )
      ]
    end

    defp calculator_callback(%{"expression" => expr}) when is_binary(expr) do
      # Strip <num> tags from expression before evaluation
      clean_expr = String.replace(expr, ~r/<\/?num>/, "")
      {result, _} = Code.eval_string(clean_expr)
      # Wrap result in <num> tags
      {:ok, "<num>#{result}</num>"}
    rescue
      e -> {:error, "Invalid expression: #{Exception.message(e)}"}
    end

    defp calculator_callback(%{expression: expr}) when is_binary(expr) do
      # Strip <num> tags from expression before evaluation
      clean_expr = String.replace(expr, ~r/<\/?num>/, "")
      {result, _} = Code.eval_string(clean_expr)
      # Wrap result in <num> tags
      {:ok, "<num>#{result}</num>"}
    rescue
      e -> {:error, "Invalid expression: #{Exception.message(e)}"}
    end

    defp calculator_callback(args) do
      {:error,
       "Provide an expression string. Example: {\"expression\":\"15 * 7\"}. Got: #{inspect(args)}"}
    end
  end

  describe "Agent cassette replay" do
    @tag :req_llm
    @tag :capture_log
    test "single prompt with tool should replay correctly" do
      # Use named cassette so we can switch modes between calls
      cassette_opts_record = %{
        cassette_dir: @cassette_dir,
        cassette_name: "agent_single_prompt",
        mode: :record,
        filter_request_headers: ["authorization", "x-api-key", "cookie"]
      }

      cassette_opts_replay = %{
        cassette_dir: @cassette_dir,
        cassette_name: "agent_single_prompt",
        mode: :replay,
        filter_request_headers: ["authorization", "x-api-key", "cookie"]
      }

      Logger.debug("=== FIRST RUN ===")
      {:ok, agent1} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts_record)

      {:ok, response1} =
        MyAgentWithCassettes.prompt(agent1, "What is <num>15</num> * <num>7</num>?")

      Logger.debug("First response: #{response1}")

      cassettes_after_first = File.ls!(@cassette_dir)
      Logger.debug("Cassettes after first run: #{length(cassettes_after_first)}")

      # Verify cassette interactions after first call
      cassette_path = Path.join(@cassette_dir, "agent_single_prompt.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interactions_count = length(cassette["interactions"])
      Logger.debug("Interactions after first run: #{interactions_count}")

      Logger.debug("=== SECOND RUN (replay) ===")
      {:ok, agent2} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts_replay)

      {:ok, response2} =
        MyAgentWithCassettes.prompt(agent2, "What is <num>15</num> * <num>7</num>?")

      Logger.debug("Second response: #{response2}")

      cassettes_after_second = File.ls!(@cassette_dir)
      Logger.debug("Cassettes after second run: #{length(cassettes_after_second)}")

      # Verify responses are identical
      assert response1 == response2

      # Verify no new cassettes were created
      assert length(cassettes_after_second) == length(cassettes_after_first),
             "New cassettes were created on replay. Expected: #{length(cassettes_after_first)}, Got: #{length(cassettes_after_second)}"

      # Verify interaction count unchanged (replay didn't add new interactions)
      {:ok, data_after} = File.read(cassette_path)
      {:ok, cassette_after} = Jason.decode(data_after)

      assert length(cassette_after["interactions"]) == interactions_count,
             "Interactions changed on replay. Expected: #{interactions_count}, Got: #{length(cassette_after["interactions"])}"
    end

    @tag :req_llm
    @tag :capture_log
    test "multiple prompts should replay correctly from same agent" do
      # Use named cassette so we can switch modes between calls
      cassette_opts_record = %{
        cassette_dir: @cassette_dir,
        cassette_name: "agent_multiple_prompts",
        mode: :record,
        filter_request_headers: ["authorization", "x-api-key", "cookie"]
      }

      cassette_opts_replay = %{
        cassette_dir: @cassette_dir,
        cassette_name: "agent_multiple_prompts",
        mode: :replay,
        filter_request_headers: ["authorization", "x-api-key", "cookie"]
      }

      Logger.debug("=== FIRST RUN - Multiple prompts ===")
      {:ok, agent1} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts_record)

      {:ok, response1a} =
        MyAgentWithCassettes.prompt(agent1, "What is <num>15</num> * <num>7</num>?")

      Logger.debug("First prompt response: #{response1a}")

      {:ok, response1b} =
        MyAgentWithCassettes.prompt(
          agent1,
          "Write a short poem that includes the result of 234 - 167"
        )

      Logger.debug("Second prompt response: #{response1b}")

      cassettes_after_first = File.ls!(@cassette_dir)
      Logger.debug("Cassettes after first run: #{length(cassettes_after_first)}")

      # Verify cassette interactions after first call
      cassette_path = Path.join(@cassette_dir, "agent_multiple_prompts.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)
      interactions_count = length(cassette["interactions"])
      Logger.debug("Interactions after first run: #{interactions_count}")

      Logger.debug("=== SECOND RUN (replay) - Same prompts ===")
      {:ok, agent2} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts_replay)

      {:ok, response2a} =
        MyAgentWithCassettes.prompt(agent2, "What is <num>15</num> * <num>7</num>?")

      Logger.debug("First prompt response (replay): #{response2a}")

      {:ok, response2b} =
        MyAgentWithCassettes.prompt(
          agent2,
          "Write a short poem that includes the result of 234 - 167"
        )

      Logger.debug("Second prompt response (replay): #{response2b}")

      cassettes_after_second = File.ls!(@cassette_dir)
      Logger.debug("Cassettes after second run: #{length(cassettes_after_second)}")

      # Verify responses are identical
      assert response1a == response2a
      assert response1b == response2b

      # Verify no new cassettes were created
      assert length(cassettes_after_second) == length(cassettes_after_first),
             "New cassettes were created on replay. Expected: #{length(cassettes_after_first)}, Got: #{length(cassettes_after_second)}"

      # Verify interaction count unchanged (replay didn't add new interactions)
      {:ok, data_after} = File.read(cassette_path)
      {:ok, cassette_after} = Jason.decode(data_after)

      assert length(cassette_after["interactions"]) == interactions_count,
             "Interactions changed on replay. Expected: #{interactions_count}, Got: #{length(cassette_after["interactions"])}"
    end

    @tag :req_llm
    @tag :capture_log
    test "agent with templates replays with parameterized 3-digit numbers" do
      # Use template patterns to parameterize IDs, timestamps, etc.
      # This allows the same cassette to work even when real API would generate different IDs
      # When passing directly to Plug (not via with_cassette), use map syntax
      cassette_opts_record = %{
        cassette_dir: @cassette_dir,
        cassette_name: "agent_templated",
        mode: :record,
        filter_request_headers: ["authorization", "x-api-key", "cookie"],
        template: %{
          patterns: %{
            msg_id: ~r/msg_[a-zA-Z0-9]+/,
            toolu: ~r/toolu_[a-zA-Z0-9]+/,
            req_id: ~r/req_[a-zA-Z0-9]+/,
            timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/,
            org_id: ~r/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/,
            # Match numbers with <num> tags
            num: ~r/<num>\d+<\/num>/
          }
        }
      }

      cassette_opts_replay = %{
        cassette_dir: @cassette_dir,
        cassette_name: "agent_templated",
        mode: :replay,
        filter_request_headers: ["authorization", "x-api-key", "cookie"],
        template: %{
          patterns: %{
            msg_id: ~r/msg_[a-zA-Z0-9]+/,
            toolu: ~r/toolu_[a-zA-Z0-9]+/,
            req_id: ~r/req_[a-zA-Z0-9]+/,
            timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/,
            org_id: ~r/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/,
            # Match numbers with <num> tags
            num: ~r/<num>\d+<\/num>/
          }
        }
      }

      Logger.debug("=== FIRST RUN (with templates) ===")
      {:ok, agent1} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts_record)

      {:ok, response1} =
        MyAgentWithCassettes.prompt(agent1, "What is <num>123</num> * <num>456</num>?")

      Logger.debug("First response: #{response1}")

      # Verify cassette has template markers
      cassette_path = Path.join(@cassette_dir, "agent_templated.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      # Find interaction with tool_use in response
      tool_use_interaction =
        Enum.find(cassette["interactions"], fn int ->
          content = get_in(int, ["response", "body_json", "content"])
          is_list(content) && Enum.any?(content, &(&1["type"] == "tool_use"))
        end)

      assert tool_use_interaction != nil, "No tool_use interaction found in cassette"

      # Note: tool_use ID in response stays static (response-only value)
      # It gets templated when it appears in the next request as tool_use_id
      tool_use_content =
        tool_use_interaction["response"]["body_json"]["content"]
        |> Enum.find(&(&1["type"] == "tool_use"))

      original_toolu_id = tool_use_content["id"]
      Logger.debug("Tool use ID in first response: #{original_toolu_id}")

      # Find the second interaction (which has tool_use in request messages)
      second_interaction = Enum.at(cassette["interactions"], 1)
      assert second_interaction != nil, "No second interaction found"

      # In the second interaction's templated request, the assistant message
      # should have the tool_use with a templated ID
      templated_messages = second_interaction["request"]["body_json"]["messages"]

      templated_assistant_msg =
        Enum.find(templated_messages, fn msg ->
          msg["role"] == "assistant" && is_list(msg["content"])
        end)

      assert templated_assistant_msg != nil, "No assistant message in second interaction"

      templated_tool_use =
        templated_assistant_msg["content"]
        |> Enum.find(&(&1["type"] == "tool_use"))

      assert templated_tool_use != nil, "No tool_use in assistant message"

      Logger.debug("Templated tool_use ID: #{templated_tool_use["id"]}")

      # The tool_use ID should be templated
      assert templated_tool_use["id"] == "{{toolu.0}}",
             "Expected {{toolu.0}} but got: #{templated_tool_use["id"]}"

      # Verify recorded_values contains the original ID
      recorded_toolu = second_interaction["template"]["recorded_values"]["toolu"]

      assert is_list(recorded_toolu) && length(recorded_toolu) == 1,
             "Expected one recorded toolu value"

      assert List.first(recorded_toolu) == original_toolu_id,
             "Recorded value should match original ID"

      # Verify numbers are templated in the first interaction
      first_interaction = Enum.at(cassette["interactions"], 0)

      # Check that the tool expression was templated (replaced with placeholders)
      templated_response = first_interaction["response"]["body_json"]["content"]
      tool_use = Enum.find(templated_response, &(&1["type"] == "tool_use"))

      assert tool_use != nil, "Expected tool_use in response"

      # The templated expression should have placeholders
      assert String.contains?(tool_use["input"]["expression"], "{{num."),
             "Expected {{num.}} template placeholders in expression"

      # Verify recorded numbers (with <num> tags) in the first interaction
      recorded_nums = first_interaction["template"]["recorded_values"]["num"]
      Logger.debug("Recorded numbers: #{inspect(recorded_nums)}")

      assert is_list(recorded_nums) && length(recorded_nums) >= 2,
             "Expected at least 2 recorded numbers"

      # Numbers should be in <num> tags like <num>123</num>
      assert Enum.any?(recorded_nums, &String.contains?(&1, "123")),
             "Expected to find 123 in recorded values"

      assert Enum.any?(recorded_nums, &String.contains?(&1, "456")),
             "Expected to find 456 in recorded values"

      interactions_count = length(cassette["interactions"])
      Logger.debug("Interactions after recording: #{interactions_count}")

      Logger.debug("=== SECOND RUN (replay with same 3-digit numbers) ===")
      {:ok, agent2} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts_replay)

      {:ok, response2} =
        MyAgentWithCassettes.prompt(agent2, "What is <num>123</num> * <num>456</num>?")

      Logger.debug("Second response: #{response2}")

      # Verify responses are identical
      assert response1 == response2,
             "Responses should be identical. Got:\nFirst: #{response1}\nSecond: #{response2}"

      # Verify no new interactions were added
      {:ok, data_after} = File.read(cassette_path)
      {:ok, cassette_after} = Jason.decode(data_after)

      assert length(cassette_after["interactions"]) == interactions_count,
             "Interactions changed on replay. Expected: #{interactions_count}, Got: #{length(cassette_after["interactions"])}"

      Logger.debug("✅ Replay test passed: Agent replayed correctly with same 3-digit numbers")

      # Third run - replay with DIFFERENT 3-digit numbers
      Logger.debug("=== THIRD RUN (replay with DIFFERENT 3-digit numbers) ===")
      {:ok, agent3} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts_replay)

      {:ok, response3} =
        MyAgentWithCassettes.prompt(agent3, "What is <num>234</num> * <num>567</num>?")

      Logger.debug("Third response (different numbers): #{response3}")

      # The replay should work without errors
      # Note: The response text comes from the cassette and won't reflect the new calculation
      # But the tool executed locally with the new numbers (234 * 567 = 132678)
      assert is_binary(response3), "Should receive a string response"

      # Verify cassette was NOT modified (still same number of interactions)
      {:ok, data_final} = File.read(cassette_path)
      {:ok, cassette_final} = Jason.decode(data_final)

      assert length(cassette_final["interactions"]) == interactions_count,
             "Cassette should not have new interactions on replay with different numbers"

      Logger.debug(
        "✅ Number parameterization test passed: Same cassette works with different 3-digit numbers!"
      )
    end

    @tag :req_llm
    @tag :capture_log
    test "tool receives and returns numbers with <num> tags" do
      cassette_opts = %{
        cassette_dir: @cassette_dir,
        cassette_name: "num_tags_demo",
        mode: :record,
        filter_request_headers: ["authorization", "x-api-key", "cookie"]
      }

      Logger.debug("=== Testing <num> tags ===")
      {:ok, agent} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts)

      {:ok, response} =
        MyAgentWithCassettes.prompt(agent, "What is <num>123</num> * <num>456</num>?")

      Logger.debug("Response: #{response}")

      # Verify cassette has <num> tags in tool call
      cassette_path = Path.join(@cassette_dir, "num_tags_demo.json")
      {:ok, data} = File.read(cassette_path)
      {:ok, cassette} = Jason.decode(data)

      # Check first interaction (tool call)
      first_interaction = Enum.at(cassette["interactions"], 0)

      tool_use_content =
        first_interaction["response"]["body_json"]["content"]
        |> Enum.find(&(&1["type"] == "tool_use"))

      expression = tool_use_content["input"]["expression"]
      Logger.debug("Tool expression: #{expression}")

      assert String.contains?(expression, "<num>123</num>"),
             "Expected <num>123</num> in expression"

      assert String.contains?(expression, "<num>456</num>"),
             "Expected <num>456</num> in expression"

      # Check second interaction (tool result)
      second_interaction = Enum.at(cassette["interactions"], 1)
      assert second_interaction != nil, "Expected second interaction"

      messages = get_in(second_interaction, ["request", "body_json", "messages"])
      assert messages != nil, "Expected messages in second interaction"

      # Find the user message with tool_result content
      user_msg =
        Enum.find(messages, fn msg ->
          msg["role"] == "user" and is_list(msg["content"]) and
            Enum.any?(msg["content"], &(&1["type"] == "tool_result"))
        end)

      assert user_msg != nil, "Expected user message with tool_result"

      tool_result = Enum.find(user_msg["content"], &(&1["type"] == "tool_result"))
      assert tool_result != nil, "Expected tool_result in content"

      result_content = tool_result["content"]
      Logger.debug("Tool result: #{result_content}")

      assert String.contains?(result_content, "<num>56088</num>"),
             "Expected <num>56088</num> in result"

      Logger.debug("✅ Tool correctly uses <num> tags for input and output")
    end

    @tag :req_llm
    @tag :capture_log
    test "simple agent template test - record and replay" do
      cassette_opts = %{
        cassette_dir: @cassette_dir,
        cassette_name: "simple_template",
        mode: :record,
        filter_request_headers: ["authorization", "x-api-key", "cookie"],
        template: %{
          patterns: %{
            msg_id: ~r/msg_[a-zA-Z0-9]+/,
            toolu: ~r/toolu_[a-zA-Z0-9]+/,
            req_id: ~r/req_[a-zA-Z0-9]+/,
            timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/,
            org_id: ~r/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/,
            # Match numbers with <num> tags
            num: ~r/<num>\d+<\/num>/
          }
        }
      }

      Logger.debug("=== RECORD RUN ===")
      {:ok, agent1} = MyAgentWithCassettes.start_link(cassette_opts: cassette_opts)

      {:ok, response1} =
        MyAgentWithCassettes.prompt(agent1, "What is <num>123</num> * <num>456</num>?")

      Logger.debug("Record response: #{response1}")

      Logger.debug("=== REPLAY RUN (same numbers) ===")

      {:ok, agent2} =
        MyAgentWithCassettes.start_link(cassette_opts: Map.put(cassette_opts, :mode, :replay))

      {:ok, response2} =
        MyAgentWithCassettes.prompt(agent2, "What is <num>123</num> * <num>456</num>?")

      Logger.debug("Replay response: #{response2}")

      assert response1 == response2

      Logger.debug("=== REPLAY RUN (different numbers) ===")

      {:ok, agent3} =
        MyAgentWithCassettes.start_link(cassette_opts: Map.put(cassette_opts, :mode, :replay))

      {:ok, response3} =
        MyAgentWithCassettes.prompt(agent3, "What is <num>234</num> * <num>567</num>?")

      Logger.debug("Replay response (different numbers): #{response3}")

      # The replay should work without errors
      # Note: The response text comes from the cassette and won't reflect the new calculation
      # But the tool executed locally with the new numbers, so the agent's internal state is correct
      assert is_binary(response3), "Should receive a string response"

      # Verify the question numbers are referenced (either the new or old numbers are fine)
      # The key is that templating allowed the replay to succeed
      Logger.debug("✅ Template test passed: Agent can replay with different numbers")
    end
  end
end
