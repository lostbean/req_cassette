defmodule ReqCassette.CrossProcessTest do
  @moduledoc """
  Tests for cross-process behavior with sequential matching.

  These tests verify that sequential matching works correctly when HTTP requests
  are made from spawned processes (Task.async, GenServer, etc.). Cross-process
  matching requires an explicit shared session created via `start_shared_session/0`.
  """
  use ExUnit.Case, async: true

  import ReqCassette
  alias Plug.Conn
  alias ReqCassette.Cassette

  @cassette_dir "test/fixtures/cross_process"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "cross-process sequential matching with shared session" do
    test "spawned processes share session state via explicit shared session" do
      bypass = Bypass.open()

      # Set up a counter to track request order
      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{request_number: current}))
      end)

      # Create a shared session for cross-process matching
      session = ReqCassette.start_shared_session()

      try do
        # Record 3 requests sequentially from the parent process
        with_cassette(
          "task_async_test",
          [
            cassette_dir: @cassette_dir,
            mode: :record,
            session: session,
            template: [preset: :common]
          ],
          fn plug ->
            r1 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            r2 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            r3 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            assert r1.body["request_number"] == 1
            assert r2.body["request_number"] == 2
            assert r3.body["request_number"] == 3
          end
        )
      after
        ReqCassette.end_shared_session(session)
      end

      # Verify cassette has 3 interactions
      cassette_path = Path.join(@cassette_dir, "task_async_test.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Replay from spawned processes - requires shared session
      Bypass.down(bypass)

      # Create a new shared session for replay
      replay_session = ReqCassette.start_shared_session()

      try do
        with_cassette(
          "task_async_test",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            session: replay_session,
            template: [preset: :common]
          ],
          fn plug ->
            # Make requests from spawned tasks
            # With shared session, all processes share the same state
            tasks =
              for _i <- 1..3 do
                Task.async(fn ->
                  Req.post!("http://localhost:#{bypass.port}/api",
                    plug: plug,
                    json: %{action: "query"}
                  )
                end)
              end

            results = Task.await_many(tasks)
            numbers = Enum.map(results, & &1.body["request_number"]) |> Enum.sort()

            # All three requests should get different interactions
            assert numbers == [1, 2, 3],
                   "Expected sequential responses [1, 2, 3] but got #{inspect(numbers)}"
          end
        )
      after
        ReqCassette.end_shared_session(replay_session)
      end
    end

    test "interleaved parent/child requests work correctly with shared session" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/data", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{seq: current}))
      end)

      # Create a shared session
      session = ReqCassette.start_shared_session()

      try do
        # Record: request from parent, then spawned process, then parent again
        with_cassette(
          "spawn_interleave_test",
          [
            cassette_dir: @cassette_dir,
            mode: :record,
            session: session,
            template: [preset: :common]
          ],
          fn plug ->
            # Request 1 from parent
            r1 =
              Req.post!("http://localhost:#{bypass.port}/data",
                plug: plug,
                json: %{from: "parent_1"}
              )

            assert r1.body["seq"] == 1

            # Request 2 from spawned process
            task =
              Task.async(fn ->
                Req.post!("http://localhost:#{bypass.port}/data",
                  plug: plug,
                  json: %{from: "child"}
                )
              end)

            r2 = Task.await(task)
            assert r2.body["seq"] == 2

            # Request 3 from parent
            r3 =
              Req.post!("http://localhost:#{bypass.port}/data",
                plug: plug,
                json: %{from: "parent_2"}
              )

            assert r3.body["seq"] == 3
          end
        )
      after
        ReqCassette.end_shared_session(session)
      end

      cassette_path = Path.join(@cassette_dir, "spawn_interleave_test.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Replay with shared session
      Bypass.down(bypass)

      replay_session = ReqCassette.start_shared_session()

      try do
        with_cassette(
          "spawn_interleave_test",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            session: replay_session,
            template: [preset: :common]
          ],
          fn plug ->
            # Request 1 from parent - should be seq=1
            r1 =
              Req.post!("http://localhost:#{bypass.port}/data",
                plug: plug,
                json: %{from: "parent_1"}
              )

            assert r1.body["seq"] == 1, "Parent request 1 should get seq=1"

            # Request 2 from spawned process - should get seq=2
            task =
              Task.async(fn ->
                Req.post!("http://localhost:#{bypass.port}/data",
                  plug: plug,
                  json: %{from: "child"}
                )
              end)

            r2 = Task.await(task)

            assert r2.body["seq"] == 2,
                   "Child request should get seq=2 but got seq=#{r2.body["seq"]}"

            # Request 3 from parent - should get seq=3
            r3 =
              Req.post!("http://localhost:#{bypass.port}/data",
                plug: plug,
                json: %{from: "parent_2"}
              )

            assert r3.body["seq"] == 3,
                   "Parent request 2 should get seq=3 but got seq=#{r3.body["seq"]}"
          end
        )
      after
        ReqCassette.end_shared_session(replay_session)
      end
    end
  end

  describe "default behavior (no shared session)" do
    test "single-process requests work without shared session" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{request_number: current}))
      end)

      # Record without shared session (uses process dictionary)
      with_cassette(
        "single_process_test",
        [
          cassette_dir: @cassette_dir,
          mode: :record,
          template: [preset: :common]
        ],
        fn plug ->
          r1 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{action: "query"}
            )

          r2 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{action: "query"}
            )

          assert r1.body["request_number"] == 1
          assert r2.body["request_number"] == 2
        end
      )

      # Verify cassette has 2 interactions
      cassette_path = Path.join(@cassette_dir, "single_process_test.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 2

      Bypass.down(bypass)

      # Replay without shared session - works for single process
      with_cassette(
        "single_process_test",
        [
          cassette_dir: @cassette_dir,
          mode: :replay,
          template: [preset: :common]
        ],
        fn plug ->
          r1 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{action: "query"}
            )

          r2 =
            Req.post!("http://localhost:#{bypass.port}/api",
              plug: plug,
              json: %{action: "query"}
            )

          assert r1.body["request_number"] == 1
          assert r2.body["request_number"] == 2
        end
      )
    end
  end

  describe "cassette reuse within same shared session (Bug 1 fix)" do
    test "same cassette can be used multiple times in one shared session" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{request_number: current}))
      end)

      # Create a single shared session
      session = ReqCassette.start_shared_session()

      try do
        # Record cassette with 2 interactions
        with_cassette(
          "reuse_test",
          [
            cassette_dir: @cassette_dir,
            mode: :record,
            session: session,
            template: [preset: :common]
          ],
          fn plug ->
            r1 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            r2 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            assert r1.body["request_number"] == 1
            assert r2.body["request_number"] == 2
          end
        )

        # Verify cassette has 2 interactions
        cassette_path = Path.join(@cassette_dir, "reuse_test.json")
        {:ok, cassette} = Cassette.load(cassette_path)
        assert length(cassette["interactions"]) == 2

        Bypass.down(bypass)

        # First replay - should get interactions 1 and 2
        with_cassette(
          "reuse_test",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            session: session,
            template: [preset: :common]
          ],
          fn plug ->
            r1 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            r2 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            assert r1.body["request_number"] == 1,
                   "First replay, request 1 should get request_number=1"

            assert r2.body["request_number"] == 2,
                   "First replay, request 2 should get request_number=2"
          end
        )

        # Second replay of SAME cassette in SAME session - should reset to start
        with_cassette(
          "reuse_test",
          [
            cassette_dir: @cassette_dir,
            mode: :replay,
            session: session,
            template: [preset: :common]
          ],
          fn plug ->
            r1 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            r2 =
              Req.post!("http://localhost:#{bypass.port}/api",
                plug: plug,
                json: %{action: "query"}
              )

            # Bug 1 fix: These should start from 1 again, not continue from 3
            assert r1.body["request_number"] == 1,
                   "Second replay, request 1 should get request_number=1 (not stale index)"

            assert r2.body["request_number"] == 2,
                   "Second replay, request 2 should get request_number=2 (not stale index)"
          end
        )
      after
        ReqCassette.end_shared_session(session)
      end
    end
  end

  describe "Session cleanup" do
    test "shared session cleans up Agent process when ended" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      session = ReqCassette.start_shared_session()

      # Verify the Agent process is alive
      assert Process.alive?(session), "Session Agent should be alive after creation"

      # Use the session with a cassette
      with_cassette(
        "session_cleanup_test",
        [
          cassette_dir: @cassette_dir,
          mode: :record,
          session: session,
          template: [preset: :common]
        ],
        fn plug ->
          Req.post!("http://localhost:#{bypass.port}/api",
            plug: plug,
            json: %{action: "query"}
          )

          Req.post!("http://localhost:#{bypass.port}/api",
            plug: plug,
            json: %{action: "query"}
          )
        end
      )

      # Agent should still be alive before ending session
      assert Process.alive?(session), "Session Agent should be alive before end_shared_session"

      # End the session
      ReqCassette.end_shared_session(session)

      # Give the process a moment to terminate
      Process.sleep(10)

      # Verify the Agent process was stopped
      refute Process.alive?(session), "Session Agent should be stopped after end_shared_session"
    end
  end

  describe "nested with_cassette in shared session" do
    test "nested cassette with same name keeps index monotonic in shared session" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/nested", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{n: current}))
      end)

      session = ReqCassette.start_shared_session()

      try do
        # Record: outer request 1, inner request 2, outer request 3
        with_cassette(
          "nested_shared_session",
          [cassette_dir: @cassette_dir, mode: :record, session: session, sequential: true],
          fn plug ->
            r1 = Req.get!("http://localhost:#{bypass.port}/nested", plug: plug)
            assert r1.body["n"] == 1

            # Nested with_cassette with same cassette name
            with_cassette(
              "nested_shared_session",
              [cassette_dir: @cassette_dir, mode: :record, session: session, sequential: true],
              fn inner_plug ->
                r2 = Req.get!("http://localhost:#{bypass.port}/nested", plug: inner_plug)
                assert r2.body["n"] == 2
              end
            )

            # After nested exits, should continue from index 2, not restart at 0
            r3 = Req.get!("http://localhost:#{bypass.port}/nested", plug: plug)
            assert r3.body["n"] == 3
          end
        )
      after
        ReqCassette.end_shared_session(session)
      end

      # Verify cassette has 3 interactions
      cassette_path = Path.join(@cassette_dir, "nested_shared_session.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Create new session for replay
      session2 = ReqCassette.start_shared_session()

      try do
        # Replay: should get interactions 0, 1, 2 in order
        with_cassette(
          "nested_shared_session",
          [cassette_dir: @cassette_dir, mode: :replay, session: session2, sequential: true],
          fn plug ->
            r1 = Req.get!("http://localhost:#{bypass.port}/nested", plug: plug)
            assert r1.body["n"] == 1, "First request should return interaction 0 (n=1)"

            # Nested with_cassette with same cassette name
            with_cassette(
              "nested_shared_session",
              [cassette_dir: @cassette_dir, mode: :replay, session: session2, sequential: true],
              fn inner_plug ->
                r2 = Req.get!("http://localhost:#{bypass.port}/nested", plug: inner_plug)
                assert r2.body["n"] == 2, "Nested request should return interaction 1 (n=2)"
              end
            )

            # After nested exits, should continue from index 2, not restart at 0
            r3 = Req.get!("http://localhost:#{bypass.port}/nested", plug: plug)

            assert r3.body["n"] == 3,
                   "Third request should return interaction 2 (n=3), not restart at 0"
          end
        )
      after
        ReqCassette.end_shared_session(session2)
      end
    end

    test "spawned process in nested shared session cassette maintains correct index" do
      bypass = Bypass.open()

      request_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/spawn_nested", fn conn ->
        :counters.add(request_count, 1, 1)
        current = :counters.get(request_count, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(200, Jason.encode!(%{n: current}))
      end)

      session = ReqCassette.start_shared_session()

      try do
        # Record: request from parent, request from spawned task, request from parent again
        with_cassette(
          "spawn_nested_shared",
          [cassette_dir: @cassette_dir, mode: :record, session: session, sequential: true],
          fn plug ->
            r1 = Req.get!("http://localhost:#{bypass.port}/spawn_nested", plug: plug)
            assert r1.body["n"] == 1

            # Spawned task makes a request
            task =
              Task.async(fn ->
                Req.get!("http://localhost:#{bypass.port}/spawn_nested", plug: plug)
              end)

            r2 = Task.await(task)
            assert r2.body["n"] == 2

            # Parent continues
            r3 = Req.get!("http://localhost:#{bypass.port}/spawn_nested", plug: plug)
            assert r3.body["n"] == 3
          end
        )
      after
        ReqCassette.end_shared_session(session)
      end

      # Verify cassette
      cassette_path = Path.join(@cassette_dir, "spawn_nested_shared.json")
      {:ok, cassette} = Cassette.load(cassette_path)
      assert length(cassette["interactions"]) == 3

      # Create new session for replay
      session2 = ReqCassette.start_shared_session()

      try do
        with_cassette(
          "spawn_nested_shared",
          [cassette_dir: @cassette_dir, mode: :replay, session: session2, sequential: true],
          fn plug ->
            r1 = Req.get!("http://localhost:#{bypass.port}/spawn_nested", plug: plug)
            assert r1.body["n"] == 1

            task =
              Task.async(fn ->
                Req.get!("http://localhost:#{bypass.port}/spawn_nested", plug: plug)
              end)

            r2 = Task.await(task)
            assert r2.body["n"] == 2

            r3 = Req.get!("http://localhost:#{bypass.port}/spawn_nested", plug: plug)
            assert r3.body["n"] == 3
          end
        )
      after
        ReqCassette.end_shared_session(session2)
      end
    end
  end
end
