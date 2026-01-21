defmodule ReqCassette.SequentialMatchingTest do
  @moduledoc """
  Tests for sequential matching behavior.

  These tests verify:
  1. First-match (default) - same request always returns same response
  2. Sequential matching with `sequential: true` option (without templates)
  3. Sequential matching automatically enabled with templates
  4. Error cases when sequential matching fails
  5. Integration of sequential with match_requests_on options
  """
  use ExUnit.Case, async: true

  import ReqCassette
  alias Plug.Conn
  alias ReqCassette.Cassette

  @cassette_dir "test/fixtures/sequential_matching"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "first-match (default behavior)" do
    test "same request returns same response every time" do
      bypass = Bypass.open()

      # Counter to track how many times the endpoint was hit during recording
      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/status", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{count: current}))
      end)

      # First, record using sequential: true so we get 3 different interactions
      with_cassette(
        "first_match_default",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/status", plug: plug)
          r2 = Req.get!("http://localhost:#{bypass.port}/status", plug: plug)
          r3 = Req.get!("http://localhost:#{bypass.port}/status", plug: plug)

          # During recording with sequential, each request hits the server
          assert r1.body["count"] == 1
          assert r2.body["count"] == 2
          assert r3.body["count"] == 3
        end
      )

      # Verify cassette has 3 interactions
      cassette_path = Path.join(@cassette_dir, "first_match_default.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Replay with default (first-match) behavior - NO sequential option
      # All 3 requests should return the SAME response (interaction 0)
      with_cassette(
        "first_match_default",
        [cassette_dir: @cassette_dir, mode: :replay],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/status", plug: plug)
          r2 = Req.get!("http://localhost:#{bypass.port}/status", plug: plug)
          r3 = Req.get!("http://localhost:#{bypass.port}/status", plug: plug)

          # First-match: all get the same response (first matching interaction)
          assert r1.body["count"] == 1
          assert r2.body["count"] == 1
          assert r3.body["count"] == 1
        end
      )
    end

    test "different requests get different responses" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/users/1", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{name: "Alice"}))
      end)

      Bypass.expect(bypass, "GET", "/users/2", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{name: "Bob"}))
      end)

      # Record different requests
      with_cassette(
        "first_match_different",
        [cassette_dir: @cassette_dir, mode: :record],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/users/1", plug: plug)
          r2 = Req.get!("http://localhost:#{bypass.port}/users/2", plug: plug)
          r3 = Req.get!("http://localhost:#{bypass.port}/users/1", plug: plug)

          assert r1.body["name"] == "Alice"
          assert r2.body["name"] == "Bob"
          assert r3.body["name"] == "Alice"
        end
      )

      # Replay - first-match correctly routes different requests
      with_cassette(
        "first_match_different",
        [cassette_dir: @cassette_dir, mode: :replay],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/users/1", plug: plug)
          r2 = Req.get!("http://localhost:#{bypass.port}/users/2", plug: plug)
          r3 = Req.get!("http://localhost:#{bypass.port}/users/1", plug: plug)

          # Different URLs get matched to different interactions
          assert r1.body["name"] == "Alice"
          assert r2.body["name"] == "Bob"
          # Third request is same as first, gets same response
          assert r3.body["name"] == "Alice"
        end
      )
    end

    test "works correctly with retry logic" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/api/data", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{data: "success"}))
      end)

      # Record one request
      with_cassette(
        "first_match_retry",
        [cassette_dir: @cassette_dir, mode: :record],
        fn plug ->
          r = Req.get!("http://localhost:#{bypass.port}/api/data", plug: plug)
          assert r.body["data"] == "success"
        end
      )

      # Simulate retry logic - multiple requests for same endpoint
      # With first-match, all should succeed
      with_cassette(
        "first_match_retry",
        [cassette_dir: @cassette_dir, mode: :replay],
        fn plug ->
          # Simulate 3 retry attempts - all should get the same cached response
          for _ <- 1..3 do
            r = Req.get!("http://localhost:#{bypass.port}/api/data", plug: plug)
            assert r.body["data"] == "success"
          end
        end
      )
    end
  end

  describe "sequential: true (without templates)" do
    test "identical requests return different responses in order" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/job/status", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        status =
          case current do
            1 -> "pending"
            2 -> "running"
            3 -> "completed"
            _ -> "unknown"
          end

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{status: status}))
      end)

      # Record 3 polling requests
      with_cassette(
        "sequential_polling",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/job/status", plug: plug)
          r2 = Req.get!("http://localhost:#{bypass.port}/job/status", plug: plug)
          r3 = Req.get!("http://localhost:#{bypass.port}/job/status", plug: plug)

          assert r1.body["status"] == "pending"
          assert r2.body["status"] == "running"
          assert r3.body["status"] == "completed"
        end
      )

      # Verify cassette has 3 interactions
      cassette_path = Path.join(@cassette_dir, "sequential_polling.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Replay with sequential: true
      with_cassette(
        "sequential_polling",
        [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/job/status", plug: plug)
          r2 = Req.get!("http://localhost:#{bypass.port}/job/status", plug: plug)
          r3 = Req.get!("http://localhost:#{bypass.port}/job/status", plug: plug)

          # Sequential: each request gets the next interaction in order
          assert r1.body["status"] == "pending"
          assert r2.body["status"] == "running"
          assert r3.body["status"] == "completed"
        end
      )
    end

    test "mixed request types work with sequential matching" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "GET", "/api/endpoint", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{number: current}))
      end)

      Bypass.stub(bypass, "POST", "/api/endpoint", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(201, Jason.encode!(%{number: current}))
      end)

      # Record mixed request types
      with_cassette(
        "sequential_mixed",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/api/endpoint", plug: plug)
          r2 = Req.post!("http://localhost:#{bypass.port}/api/endpoint", plug: plug, json: %{})
          r3 = Req.get!("http://localhost:#{bypass.port}/api/endpoint", plug: plug)

          assert r1.body["number"] == 1
          assert r2.body["number"] == 2
          assert r3.body["number"] == 3
        end
      )

      # Replay in same order
      with_cassette(
        "sequential_mixed",
        [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/api/endpoint", plug: plug)
          r2 = Req.post!("http://localhost:#{bypass.port}/api/endpoint", plug: plug, json: %{})
          r3 = Req.get!("http://localhost:#{bypass.port}/api/endpoint", plug: plug)

          assert r1.body["number"] == 1
          assert r2.body["number"] == 2
          assert r3.body["number"] == 3
        end
      )
    end

    test "sequential: false uses first-match even when recording was sequential" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/counter", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{value: current}))
      end)

      # Record with sequential: true
      with_cassette(
        "sequential_to_first_match",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/counter", plug: plug)
          Req.get!("http://localhost:#{bypass.port}/counter", plug: plug)
          Req.get!("http://localhost:#{bypass.port}/counter", plug: plug)
        end
      )

      # Replay WITHOUT sequential (first-match behavior)
      with_cassette(
        "sequential_to_first_match",
        [cassette_dir: @cassette_dir, mode: :replay],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/counter", plug: plug)
          r2 = Req.get!("http://localhost:#{bypass.port}/counter", plug: plug)
          r3 = Req.get!("http://localhost:#{bypass.port}/counter", plug: plug)

          # First-match: all return the first interaction
          assert r1.body["value"] == 1
          assert r2.body["value"] == 1
          assert r3.body["value"] == 1
        end
      )
    end
  end

  describe "sequential matching with match_requests_on" do
    test "sequential works with match_requests_on: [:method, :uri]" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/api/action", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{result: current}))
      end)

      # Record with sequential and loose matching
      with_cassette(
        "sequential_with_match_on",
        [
          cassette_dir: @cassette_dir,
          mode: :record,
          sequential: true,
          match_requests_on: [:method, :uri]
        ],
        fn plug ->
          # Different bodies, but matching on method+uri only
          r1 =
            Req.post!("http://localhost:#{bypass.port}/api/action",
              plug: plug,
              json: %{data: "first"}
            )

          r2 =
            Req.post!("http://localhost:#{bypass.port}/api/action",
              plug: plug,
              json: %{data: "second"}
            )

          r3 =
            Req.post!("http://localhost:#{bypass.port}/api/action",
              plug: plug,
              json: %{data: "third"}
            )

          assert r1.body["result"] == 1
          assert r2.body["result"] == 2
          assert r3.body["result"] == 3
        end
      )

      # Replay with same settings but completely different bodies
      with_cassette(
        "sequential_with_match_on",
        [
          cassette_dir: @cassette_dir,
          mode: :replay,
          sequential: true,
          match_requests_on: [:method, :uri]
        ],
        fn plug ->
          # Bodies are different from recording, but match_requests_on ignores body
          r1 =
            Req.post!("http://localhost:#{bypass.port}/api/action",
              plug: plug,
              json: %{completely: "different"}
            )

          r2 =
            Req.post!("http://localhost:#{bypass.port}/api/action",
              plug: plug,
              json: %{another: "payload"}
            )

          r3 =
            Req.post!("http://localhost:#{bypass.port}/api/action",
              plug: plug,
              json: %{yet: "another"}
            )

          # Sequential matching advances through interactions
          assert r1.body["result"] == 1
          assert r2.body["result"] == 2
          assert r3.body["result"] == 3
        end
      )
    end
  end

  describe "error cases" do
    test "sequential matching past end of cassette raises error" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/limited", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      # Record only 2 interactions
      with_cassette(
        "sequential_limited",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/limited", plug: plug)
          Req.get!("http://localhost:#{bypass.port}/limited", plug: plug)
        end
      )

      # Replay with 3 requests - should fail on the 3rd
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "sequential_limited",
          [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/limited", plug: plug)
            Req.get!("http://localhost:#{bypass.port}/limited", plug: plug)
            # This should fail - no interaction at index 2
            Req.get!("http://localhost:#{bypass.port}/limited", plug: plug)
          end
        )
      end
    end

    test "sequential matching with wrong request type at index fails" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{method: "GET"}))
      end)

      Bypass.stub(bypass, "POST", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{method: "POST"}))
      end)

      # Record GET then POST
      with_cassette(
        "sequential_wrong_order",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/api", plug: plug)
          Req.post!("http://localhost:#{bypass.port}/api", plug: plug, json: %{})
        end
      )

      # Replay with POST then GET (wrong order) - should fail
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "sequential_wrong_order",
          [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
          fn plug ->
            # Expects GET at index 0, but we're sending POST
            Req.post!("http://localhost:#{bypass.port}/api", plug: plug, json: %{})
          end
        )
      end
    end
  end

  describe "templates auto-enable sequential" do
    test "template option automatically enables sequential matching" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        request = Jason.decode!(body)

        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{id: request["id"], result: current}))
      end)

      # Record with templates (sequential is automatic)
      # Use a pattern that matches alphanumeric IDs
      with_cassette(
        "template_auto_sequential",
        [
          cassette_dir: @cassette_dir,
          mode: :record,
          template: [patterns: [id: ~r/id-\w+/]]
        ],
        fn plug ->
          r1 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{id: "id-111"}
            )

          r2 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{id: "id-222"}
            )

          r3 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{id: "id-333"}
            )

          assert r1.body["result"] == 1
          assert r2.body["result"] == 2
          assert r3.body["result"] == 3
        end
      )

      # Replay with different IDs - templates + auto-sequential
      with_cassette(
        "template_auto_sequential",
        [
          cassette_dir: @cassette_dir,
          mode: :replay,
          template: [patterns: [id: ~r/id-\w+/]]
        ],
        fn plug ->
          # Different IDs, but templates make them match
          r1 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{id: "id-aaa"}
            )

          r2 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{id: "id-bbb"}
            )

          r3 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{id: "id-ccc"}
            )

          # Sequential matching advances through interactions
          assert r1.body["result"] == 1
          assert r2.body["result"] == 2
          assert r3.body["result"] == 3
        end
      )
    end
  end

  describe "cross-process with explicit sequential" do
    test "shared session with sequential: true works across processes" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/parallel", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{n: current}))
      end)

      session = ReqCassette.start_shared_session()

      try do
        # Record sequentially from parent
        with_cassette(
          "cross_process_sequential",
          [cassette_dir: @cassette_dir, mode: :record, session: session, sequential: true],
          fn plug ->
            r1 = Req.get!("http://localhost:#{bypass.port}/parallel", plug: plug)
            r2 = Req.get!("http://localhost:#{bypass.port}/parallel", plug: plug)
            r3 = Req.get!("http://localhost:#{bypass.port}/parallel", plug: plug)

            assert r1.body["n"] == 1
            assert r2.body["n"] == 2
            assert r3.body["n"] == 3
          end
        )
      after
        ReqCassette.end_shared_session(session)
      end

      # Replay from spawned processes
      session2 = ReqCassette.start_shared_session()

      try do
        with_cassette(
          "cross_process_sequential",
          [cassette_dir: @cassette_dir, mode: :replay, session: session2, sequential: true],
          fn plug ->
            # Spawn 3 tasks that make requests
            tasks =
              for _ <- 1..3 do
                Task.async(fn ->
                  Req.get!("http://localhost:#{bypass.port}/parallel", plug: plug)
                end)
              end

            results = Task.await_many(tasks)
            numbers = Enum.map(results, & &1.body["n"]) |> Enum.sort()

            # Each task gets a different interaction (1, 2, 3)
            assert numbers == [1, 2, 3]
          end
        )
      after
        ReqCassette.end_shared_session(session2)
      end
    end

    test "sequential without shared session fails for spawned processes" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/no_session", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{n: current}))
      end)

      # Record 3 interactions
      with_cassette(
        "no_session_sequential",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          Req.get!("http://localhost:#{bypass.port}/no_session", plug: plug)
          Req.get!("http://localhost:#{bypass.port}/no_session", plug: plug)
          Req.get!("http://localhost:#{bypass.port}/no_session", plug: plug)
        end
      )

      # Replay from spawned processes WITHOUT shared session
      # Each process has its own process dictionary, so they all start at index 0
      with_cassette(
        "no_session_sequential",
        [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
        fn plug ->
          tasks =
            for _ <- 1..3 do
              Task.async(fn ->
                Req.get!("http://localhost:#{bypass.port}/no_session", plug: plug)
              end)
            end

          results = Task.await_many(tasks)
          numbers = Enum.map(results, & &1.body["n"])

          # Without shared session, all spawned processes get index 0
          # (they each have their own process dictionary)
          assert numbers == [1, 1, 1]
        end
      )
    end
  end

  describe "edge cases" do
    test "empty cassette with sequential matching" do
      # Create an empty cassette manually
      cassette_path = Path.join(@cassette_dir, "empty_sequential.json")

      File.write!(
        cassette_path,
        Jason.encode!(%{"version" => "2.0", "interactions" => []})
      )

      # Any request should fail
      assert_raise RuntimeError, ~r/No matching interaction found/, fn ->
        with_cassette(
          "empty_sequential",
          [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
          fn plug ->
            Req.get!("http://example.com/anything", plug: plug)
          end
        )
      end
    end

    test "single interaction cassette with sequential works for one request" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/single", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{data: "only one"}))
      end)

      with_cassette(
        "single_sequential",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          r = Req.get!("http://localhost:#{bypass.port}/single", plug: plug)
          assert r.body["data"] == "only one"
        end
      )

      # Replay single request works
      with_cassette(
        "single_sequential",
        [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
        fn plug ->
          r = Req.get!("http://localhost:#{bypass.port}/single", plug: plug)
          assert r.body["data"] == "only one"
        end
      )
    end

    test "nested with_cassette with sequential keeps counter monotonic" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/nested", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{n: current}))
      end)

      # Record with nested calls
      with_cassette(
        "nested_sequential",
        [cassette_dir: @cassette_dir, mode: :record, sequential: true],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/nested", plug: plug)

          with_cassette(
            "nested_sequential",
            [cassette_dir: @cassette_dir, mode: :record, sequential: true],
            fn inner_plug ->
              r2 = Req.get!("http://localhost:#{bypass.port}/nested", plug: inner_plug)
              assert r2.body["n"] == 2
            end
          )

          r3 = Req.get!("http://localhost:#{bypass.port}/nested", plug: plug)

          assert r1.body["n"] == 1
          assert r3.body["n"] == 3
        end
      )

      # Replay - counter should be monotonic (not rewind on nested exit)
      with_cassette(
        "nested_sequential",
        [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
        fn plug ->
          r1 = Req.get!("http://localhost:#{bypass.port}/nested", plug: plug)

          with_cassette(
            "nested_sequential",
            [cassette_dir: @cassette_dir, mode: :replay, sequential: true],
            fn inner_plug ->
              r2 = Req.get!("http://localhost:#{bypass.port}/nested", plug: inner_plug)
              assert r2.body["n"] == 2
            end
          )

          r3 = Req.get!("http://localhost:#{bypass.port}/nested", plug: plug)

          assert r1.body["n"] == 1
          assert r3.body["n"] == 3
        end
      )
    end
  end
end
