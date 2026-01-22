defmodule ReqCassette.SessionErrorHandlingTest do
  @moduledoc """
  Tests for error handling when shared session Agent dies or becomes unavailable.

  These tests verify that the Session module raises clear, actionable errors
  instead of silently returning default values (like 0) when the Agent fails.
  """
  use ExUnit.Case, async: true

  alias ReqCassette.Session

  describe "shared session error handling" do
    test "get_and_advance_index raises when Agent is dead" do
      # Start a session and immediately kill it
      session = Session.start_shared_session()
      Session.end_shared_session(session)

      # Create a session_id that references the dead agent
      session_id = %{mode: :shared, ref: session}

      # Attempting to get index from dead agent should raise
      assert_raise RuntimeError, ~r/shared session Agent is not alive/, fn ->
        Session.get_and_advance_index("test/cassettes/test.json", session_id)
      end
    end

    test "get_current_index raises when Agent is dead" do
      session = Session.start_shared_session()
      Session.end_shared_session(session)

      session_id = %{mode: :shared, ref: session}

      assert_raise RuntimeError, ~r/shared session Agent is not alive/, fn ->
        Session.get_current_index("test/cassettes/test.json", session_id)
      end
    end

    test "advance_index raises when Agent is dead" do
      session = Session.start_shared_session()
      Session.end_shared_session(session)

      session_id = %{mode: :shared, ref: session}

      assert_raise RuntimeError, ~r/shared session Agent is not alive/, fn ->
        Session.advance_index("test/cassettes/test.json", session_id)
      end
    end

    test "start_session raises when shared session Agent is dead" do
      session = Session.start_shared_session()
      Session.end_shared_session(session)

      assert_raise RuntimeError, ~r/shared session Agent is not alive/, fn ->
        Session.start_session("test/cassettes/test.json", session)
      end
    end

    test "end_session with dead Agent does not raise (cleanup is safe)" do
      session = Session.start_shared_session()
      Session.end_shared_session(session)

      session_id = %{mode: :shared, ref: session}

      # end_session should NOT raise - it's a cleanup function
      assert :ok == Session.end_session("test/cassettes/test.json", session_id)
    end

    test "end_shared_session with dead Agent does not raise (cleanup is safe)" do
      session = Session.start_shared_session()
      Session.end_shared_session(session)

      # Calling end_shared_session again should NOT raise
      assert :ok == Session.end_shared_session(session)
    end

    test "error message includes helpful debugging information" do
      session = Session.start_shared_session()
      Session.end_shared_session(session)

      session_id = %{mode: :shared, ref: session}

      error =
        catch_error(Session.get_and_advance_index("test/cassettes/test.json", session_id))

      # Verify error message contains actionable guidance
      assert error.message =~ "session was ended prematurely"
      assert error.message =~ "start_shared_session()"
      assert error.message =~ "try/after"
    end
  end

  describe "local session (no Agent) continues to work" do
    test "local mode operations work without shared session" do
      # Start a local session (no shared agent)
      session_id = Session.start_session("test/cassettes/local.json", nil)

      assert session_id == %{mode: :local}

      # All operations should work
      assert Session.get_current_index("test/cassettes/local.json", session_id) == 0
      assert Session.get_and_advance_index("test/cassettes/local.json", session_id) == 0
      assert Session.get_current_index("test/cassettes/local.json", session_id) == 1
      assert Session.advance_index("test/cassettes/local.json", session_id) == :ok
      assert Session.get_current_index("test/cassettes/local.json", session_id) == 2
      assert Session.end_session("test/cassettes/local.json", session_id) == :ok
    end
  end
end
