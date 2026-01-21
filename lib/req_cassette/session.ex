defmodule ReqCassette.Session do
  @moduledoc """
  Tracks interaction indices for sequential cassette matching.

  Sequential matching is enabled when:
  - `sequential: true` is passed to `with_cassette/3`
  - `template: [...]` is passed (templates imply sequential matching)

  When sequential matching is enabled, requests match interactions in order
  (request 1 → interaction 0, request 2 → interaction 1, etc.) instead of
  first-match. This is essential for:
  - Identical requests expecting different responses (polling, state changes)
  - Templated cassettes where multiple requests have the same structure
  - Nested `with_cassette` calls using the same cassette name

  ## Two Modes

  ### Default Mode (Process Dictionary)

  For single-process tests (the common case), session state is stored in the process
  dictionary. This is simple and requires no setup:

      # Explicit sequential matching
      with_cassette("test", [sequential: true], fn plug ->
        Req.get!("/status")  # Matches interaction 0
        Req.get!("/status")  # Matches interaction 1
      end)

      # Templates automatically enable sequential
      with_cassette("test", [template: [preset: :common]], fn plug ->
        Req.post!(...)  # Matches interaction 0
        Req.post!(...)  # Matches interaction 1
      end)

  ### Shared Session Mode (Agent)

  For cross-process tests where HTTP requests are made from spawned processes
  (Task.async, GenServer, etc.), you must explicitly create a shared session:

      session = ReqCassette.start_shared_session()
      try do
        with_cassette("test", [session: session, sequential: true], fn plug ->
          Task.async(fn ->
            Req.post!(..., plug: plug)  # Works across processes!
          end) |> Task.await()
        end)
      after
        ReqCassette.end_shared_session(session)
      end

  The shared session uses an Agent process for cross-process state sharing.
  All operations are serialized through the Agent, guaranteeing consistency.
  """

  # Process dictionary key for default mode
  @pdict_key :req_cassette_session_state

  # ============================================================================
  # Shared Session API (Agent-based, for cross-process scenarios)
  # ============================================================================

  @doc """
  Creates a shared session for cross-process cassette matching.

  Returns an Agent pid that should be passed to `with_cassette/3` via
  the `session` option. The session must be ended with `end_shared_session/1`
  when done.

  ## Example

      session = ReqCassette.Session.start_shared_session()
      try do
        with_cassette("test", [session: session], fn plug ->
          Task.async(fn -> Req.post!(..., plug: plug) end) |> Task.await()
        end)
      after
        ReqCassette.Session.end_shared_session(session)
      end
  """
  @spec start_shared_session() :: pid()
  def start_shared_session do
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    agent
  end

  @doc """
  Ends a shared session by stopping its Agent process.

  Should be called in an `after` block to ensure cleanup even on errors.
  """
  @spec end_shared_session(pid()) :: :ok
  def end_shared_session(agent) when is_pid(agent) do
    Agent.stop(agent, :normal)
  rescue
    # Agent already stopped or process doesn't exist
    _ -> :ok
  end

  # ============================================================================
  # Internal Session Management (called by with_cassette)
  # ============================================================================

  @doc """
  Starts tracking a cassette path within a session.

  For shared sessions (Agent), initializes the path's index in the Agent state.
  For default sessions (process dictionary), initializes in pdict.

  Returns a session_id that combines the mode and tracking info.
  """
  @spec start_session(String.t(), pid() | nil) :: map()
  def start_session(cassette_path, shared_session \\ nil) do
    if is_pid(shared_session) do
      start_shared_path(cassette_path, shared_session)
    else
      start_local_path(cassette_path)
    end
  end

  @doc """
  Ends tracking for a cassette path within a session.
  """
  @spec end_session(String.t(), map()) :: :ok
  def end_session(cassette_path, session_id) do
    case session_id do
      %{mode: :shared, ref: ref} ->
        end_shared_path(cassette_path, ref)

      %{mode: :local} ->
        end_local_path(cassette_path)

      _ ->
        :ok
    end
  end

  @doc """
  Gets the current interaction index for sequential matching.
  """
  @spec get_current_index(String.t(), map()) :: non_neg_integer()
  def get_current_index(cassette_path, session_id) do
    case session_id do
      %{mode: :shared, ref: ref} ->
        get_shared_index(cassette_path, ref)

      %{mode: :local} ->
        get_local_index(cassette_path)

      _ ->
        0
    end
  end

  @doc """
  Atomically gets the current index and advances it.

  Essential for concurrent access in shared sessions to prevent race conditions.
  For local sessions, this is equivalent to get + advance but kept for API consistency.
  """
  @spec get_and_advance_index(String.t(), map()) :: non_neg_integer()
  def get_and_advance_index(cassette_path, session_id) do
    case session_id do
      %{mode: :shared, ref: ref} ->
        get_and_advance_shared_index(cassette_path, ref)

      %{mode: :local} ->
        # For local mode, no race conditions possible
        index = get_local_index(cassette_path)
        advance_local_index(cassette_path)
        index

      _ ->
        0
    end
  end

  @doc """
  Advances the interaction index after a successful match.
  """
  @spec advance_index(String.t(), map()) :: :ok
  def advance_index(cassette_path, session_id) do
    case session_id do
      %{mode: :shared, ref: ref} ->
        advance_shared_index(cassette_path, ref)

      %{mode: :local} ->
        advance_local_index(cassette_path)

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Shared Session (Agent) Implementation
  # ============================================================================

  defp start_shared_path(cassette_path, agent) do
    Agent.update(agent, fn state ->
      # Check for nested cassette (same path already active)
      {initial_index, stack} =
        case Map.get(state, cassette_path) do
          nil -> {0, []}
          %{index: idx, stack: st} -> {idx, [idx | st]}
        end

      # Update with new path state
      Map.put(state, cassette_path, %{index: initial_index, stack: stack})
    end)

    %{mode: :shared, ref: agent}
  rescue
    # Agent stopped or process doesn't exist
    _ -> %{mode: :shared, ref: agent}
  end

  defp end_shared_path(cassette_path, agent) do
    Agent.update(agent, fn state ->
      case Map.get(state, cassette_path) do
        %{stack: [_parent_start | rest], index: idx} ->
          # Nested: keep current index, just pop the stack
          Map.put(state, cassette_path, %{index: idx, stack: rest})

        _ ->
          # Top-level, remove the path
          Map.delete(state, cassette_path)
      end
    end)

    :ok
  rescue
    # Agent stopped or process doesn't exist
    _ -> :ok
  end

  defp get_shared_index(cassette_path, agent) do
    Agent.get(agent, fn state ->
      case Map.get(state, cassette_path) do
        %{index: idx} -> idx
        nil -> 0
      end
    end)
  rescue
    # Agent stopped or process doesn't exist
    _ -> 0
  end

  defp get_and_advance_shared_index(cassette_path, agent) do
    # Agent.get_and_update/2 is atomic - no race conditions possible
    Agent.get_and_update(agent, fn state ->
      case Map.get(state, cassette_path) do
        %{index: idx} = path_state ->
          new_state = Map.put(state, cassette_path, %{path_state | index: idx + 1})
          {idx, new_state}

        nil ->
          # Path not initialized - initialize with index 1, return 0
          new_state = Map.put(state, cassette_path, %{index: 1, stack: []})
          {0, new_state}
      end
    end)
  rescue
    # Agent stopped or process doesn't exist
    _ -> 0
  end

  defp advance_shared_index(cassette_path, agent) do
    Agent.update(agent, fn state ->
      case Map.get(state, cassette_path) do
        %{index: idx} = path_state ->
          Map.put(state, cassette_path, %{path_state | index: idx + 1})

        nil ->
          # Path not initialized - initialize with index 1
          Map.put(state, cassette_path, %{index: 1, stack: []})
      end
    end)

    :ok
  rescue
    # Agent stopped or process doesn't exist
    _ -> :ok
  end

  # ============================================================================
  # Local Session (Process Dictionary) Implementation
  # ============================================================================

  defp start_local_path(cassette_path) do
    state = Process.get(@pdict_key, %{})

    {initial_index, stack} =
      case Map.get(state, cassette_path) do
        nil -> {0, []}
        %{index: idx, stack: st} -> {idx, [idx | st]}
      end

    new_state = Map.put(state, cassette_path, %{index: initial_index, stack: stack})
    Process.put(@pdict_key, new_state)

    %{mode: :local}
  end

  defp end_local_path(cassette_path) do
    state = Process.get(@pdict_key, %{})

    new_state =
      case Map.get(state, cassette_path) do
        %{stack: [_parent_start | rest], index: current_idx} ->
          # Keep current index (monotonic), just pop the stack
          Map.put(state, cassette_path, %{index: current_idx, stack: rest})

        _ ->
          # Top-level, remove the path
          Map.delete(state, cassette_path)
      end

    Process.put(@pdict_key, new_state)
    :ok
  end

  defp get_local_index(cassette_path) do
    state = Process.get(@pdict_key, %{})

    case Map.get(state, cassette_path) do
      %{index: idx} -> idx
      nil -> 0
    end
  end

  defp advance_local_index(cassette_path) do
    state = Process.get(@pdict_key, %{})

    new_state =
      case Map.get(state, cassette_path) do
        %{index: idx} = path_state ->
          Map.put(state, cassette_path, %{path_state | index: idx + 1})

        nil ->
          Map.put(state, cassette_path, %{index: 1, stack: []})
      end

    Process.put(@pdict_key, new_state)
    :ok
  end
end
