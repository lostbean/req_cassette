defmodule ReqCassette.NestedTemplateTest do
  @moduledoc """
  Tests for nested `with_cassette` calls with the same cassette name and templates enabled.

  This tests a specific bug where nested cassettes using the same file would incorrectly
  match interactions because `find_interaction` always returns the first match without
  tracking which interactions have been used within a session.
  """
  use ExUnit.Case, async: true

  import ReqCassette
  alias Plug.Conn
  alias ReqCassette.Cassette

  @cassette_dir "test/fixtures/nested_template"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "nested with_cassette with same name and templates" do
    test "sequential requests match correct interactions" do
      bypass = Bypass.open()

      # Record phase: Set up 3 distinct responses
      # Interaction 1: Initial request
      # Interaction 2: Inner nested request (different prompt)
      # Interaction 3: Final request (references tool_id from #1)

      tool_id = "toolu_#{:rand.uniform(999_999)}"

      Bypass.expect(bypass, "POST", "/chat", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        request = Jason.decode!(body)
        messages = request["messages"]
        # Check the last message for routing (for the multi-turn case)
        last_content = get_in(messages, [Access.at(-1), "content"])

        response =
          cond do
            # Response 3: final response (has tool result context)
            String.contains?(to_string(last_content), "final") ->
              %{id: "msg_3", content: [%{type: "text", text: "final result"}]}

            # Response 2: inner tool's response
            String.contains?(to_string(last_content), "inner") ->
              %{id: "msg_2", content: [%{type: "text", text: "inner result"}]}

            # Response 1: includes tool_use (single message with "initial")
            String.contains?(to_string(last_content), "initial") ->
              %{id: "msg_1", content: [%{type: "tool_use", id: tool_id, name: "search"}]}

            true ->
              # Fallback
              %{id: "msg_unknown", content: [%{type: "text", text: "unknown"}]}
          end

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(response))
      end)

      # First: Record the cassette
      with_cassette(
        "nested_test",
        [
          cassette_dir: @cassette_dir,
          mode: :record,
          template: [preset: :anthropic]
        ],
        fn outer_plug ->
          # Request 1
          r1 =
            Req.post!("http://localhost:#{bypass.port}/chat",
              plug: outer_plug,
              json: %{messages: [%{role: "user", content: "initial request"}]}
            )

          recorded_tool_id = get_in(r1.body, ["content", Access.at(0), "id"])

          # Nested with_cassette (same name!)
          with_cassette(
            "nested_test",
            [
              cassette_dir: @cassette_dir,
              mode: :record,
              template: [preset: :anthropic]
            ],
            fn inner_plug ->
              # Request 2 (inner)
              Req.post!("http://localhost:#{bypass.port}/chat",
                plug: inner_plug,
                json: %{messages: [%{role: "user", content: "inner request"}]}
              )
            end
          )

          # Request 3 (references tool_id)
          Req.post!("http://localhost:#{bypass.port}/chat",
            plug: outer_plug,
            json: %{
              messages: [
                %{role: "user", content: "initial request"},
                %{role: "assistant", content: [%{type: "tool_use", id: recorded_tool_id}]},
                %{role: "user", content: "final request with tool result"}
              ]
            }
          )
        end
      )

      # Verify cassette was recorded with 3 interactions
      cassette_path = Path.join(@cassette_dir, "nested_test.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Now: Replay with DIFFERENT values
      # This is where the bug manifests - inner cassette might match wrong interaction
      Bypass.down(bypass)

      with_cassette(
        "nested_test",
        [
          cassette_dir: @cassette_dir,
          mode: :replay,
          template: [preset: :anthropic]
        ],
        fn outer_plug ->
          # Request 1 - should match interaction 1
          r1 =
            Req.post!("http://localhost:#{bypass.port}/chat",
              plug: outer_plug,
              json: %{messages: [%{role: "user", content: "initial request"}]}
            )

          replayed_tool_id = get_in(r1.body, ["content", Access.at(0), "id"])
          assert r1.body["id"] == "msg_1"

          # Nested with_cassette (same name!)
          with_cassette(
            "nested_test",
            [
              cassette_dir: @cassette_dir,
              mode: :replay,
              template: [preset: :anthropic]
            ],
            fn inner_plug ->
              # Request 2 - should match interaction 2, NOT interaction 1
              r2 =
                Req.post!("http://localhost:#{bypass.port}/chat",
                  plug: inner_plug,
                  json: %{messages: [%{role: "user", content: "inner request"}]}
                )

              assert r2.body["id"] == "msg_2",
                     "Expected msg_2 but got #{r2.body["id"]} - inner cassette matched wrong interaction"
            end
          )

          # Request 3 - should match interaction 3
          r3 =
            Req.post!("http://localhost:#{bypass.port}/chat",
              plug: outer_plug,
              json: %{
                messages: [
                  %{role: "user", content: "initial request"},
                  %{role: "assistant", content: [%{type: "tool_use", id: replayed_tool_id}]},
                  %{role: "user", content: "final request with tool result"}
                ]
              }
            )

          assert r3.body["id"] == "msg_3",
                 "Expected msg_3 but got #{r3.body["id"]} - outer cassette matched wrong interaction"
        end
      )
    end

    test "multiple requests within single cassette advance sequentially" do
      bypass = Bypass.open()

      # Set up 3 identical-structure requests with different responses
      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        _count = :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{request_number: current}))
      end)

      # Record 3 requests with identical structure
      with_cassette(
        "sequential_test",
        [
          cassette_dir: @cassette_dir,
          mode: :record,
          template: [preset: :common]
        ],
        fn plug ->
          r1 =
            Req.post!("http://localhost:#{bypass.port}/api", plug: plug, json: %{action: "query"})

          r2 =
            Req.post!("http://localhost:#{bypass.port}/api", plug: plug, json: %{action: "query"})

          r3 =
            Req.post!("http://localhost:#{bypass.port}/api", plug: plug, json: %{action: "query"})

          assert r1.body["request_number"] == 1
          assert r2.body["request_number"] == 2
          assert r3.body["request_number"] == 3
        end
      )

      # Verify cassette has 3 interactions
      cassette_path = Path.join(@cassette_dir, "sequential_test.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Replay - should get same sequence
      Bypass.down(bypass)

      with_cassette(
        "sequential_test",
        [
          cassette_dir: @cassette_dir,
          mode: :replay,
          template: [preset: :common]
        ],
        fn plug ->
          r1 =
            Req.post!("http://localhost:#{bypass.port}/api", plug: plug, json: %{action: "query"})

          r2 =
            Req.post!("http://localhost:#{bypass.port}/api", plug: plug, json: %{action: "query"})

          r3 =
            Req.post!("http://localhost:#{bypass.port}/api", plug: plug, json: %{action: "query"})

          assert r1.body["request_number"] == 1,
                 "Expected request 1 but got #{r1.body["request_number"]}"

          assert r2.body["request_number"] == 2,
                 "Expected request 2 but got #{r2.body["request_number"]}"

          assert r3.body["request_number"] == 3,
                 "Expected request 3 but got #{r3.body["request_number"]}"
        end
      )
    end
  end

  describe "nested helper pattern (Bug 1 fix - monotonic counter)" do
    @tag :bug1_fix
    test "nested with_cassette keeps counter monotonic, not restoring parent index" do
      # This tests the bug where nested with_cassette calls to the same file
      # would restore the parent's index, causing incorrect matching.
      #
      # Scenario:
      # 1. Outer cassette starts at index 0
      # 2. Request #1 -> matches interaction 0, advances to index 1
      # 3. Inner with_cassette (same file) enters, pushes 1 to stack
      # 4. Inner request -> matches interaction 1, advances to index 2
      # 5. Inner with_cassette ends
      # 6. BUG: old code restored index to 1 (from stack)
      # 7. Outer request #2 -> would incorrectly match interaction 1 again
      #
      # FIX: Counter should stay at 2, not rewind to 1

      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/helper", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{seq: current}))
      end)

      # Helper function that uses with_cassette internally (common pattern)
      helper_fn = fn plug ->
        with_cassette(
          "helper_nested_test",
          [
            cassette_dir: @cassette_dir,
            mode: :record,
            template: [preset: :common]
          ],
          fn _inner_plug ->
            # This is the inner with_cassette call
            Req.post!("http://localhost:#{bypass.port}/helper",
              plug: plug,
              json: %{from: "helper"}
            )
          end
        )
      end

      # Record: outer -> helper (nested) -> outer
      with_cassette(
        "helper_nested_test",
        [
          cassette_dir: @cassette_dir,
          mode: :record,
          template: [preset: :common]
        ],
        fn plug ->
          # Request 1 from outer
          r1 =
            Req.post!("http://localhost:#{bypass.port}/helper",
              plug: plug,
              json: %{from: "outer_1"}
            )

          assert r1.body["seq"] == 1

          # Request 2 from helper (nested with_cassette same file)
          r2 = helper_fn.(plug)
          assert r2.body["seq"] == 2

          # Request 3 from outer - THIS IS WHERE THE BUG MANIFESTED
          # Before fix: would get seq=2 (counter rewound to 1)
          # After fix: should get seq=3 (counter stayed at 2)
          r3 =
            Req.post!("http://localhost:#{bypass.port}/helper",
              plug: plug,
              json: %{from: "outer_2"}
            )

          assert r3.body["seq"] == 3,
                 "Bug 1 regression: Expected seq=3 but got #{r3.body["seq"]}. Counter was rewound instead of staying monotonic."
        end
      )

      # Verify cassette has 3 interactions
      cassette_path = Path.join(@cassette_dir, "helper_nested_test.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Replay: same pattern should work
      Bypass.down(bypass)

      with_cassette(
        "helper_nested_test",
        [
          cassette_dir: @cassette_dir,
          mode: :replay,
          template: [preset: :common]
        ],
        fn plug ->
          r1 =
            Req.post!("http://localhost:#{bypass.port}/helper",
              plug: plug,
              json: %{from: "outer_1"}
            )

          assert r1.body["seq"] == 1

          # Use a simpler nested pattern for replay
          with_cassette(
            "helper_nested_test",
            [
              cassette_dir: @cassette_dir,
              mode: :replay,
              template: [preset: :common]
            ],
            fn _inner_plug ->
              Req.post!("http://localhost:#{bypass.port}/helper",
                plug: plug,
                json: %{from: "helper"}
              )
            end
          )
          |> then(fn r2 ->
            assert r2.body["seq"] == 2
          end)

          r3 =
            Req.post!("http://localhost:#{bypass.port}/helper",
              plug: plug,
              json: %{from: "outer_2"}
            )

          assert r3.body["seq"] == 3,
                 "Bug 1 regression (replay): Expected seq=3 but got #{r3.body["seq"]}"
        end
      )
    end
  end
end
