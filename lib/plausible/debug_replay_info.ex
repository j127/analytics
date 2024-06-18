defmodule Plausible.DebugReplayInfo do
  @moduledoc """
  Function execution context (with arguments) to Sentry reports.
  """

  require Logger

  defmacro __using__(_) do
    quote do
      require Plausible.DebugReplayInfo
      import Plausible.DebugReplayInfo, only: [include_sentry_replay_info: 0]
    end
  end

  defmacro include_sentry_replay_info() do
    module = __CALLER__.module
    {function, arity} = __CALLER__.function
    f = Function.capture(module, function, arity)

    quote bind_quoted: [f: f] do
      replay_info =
        {f, binding()}
        |> :erlang.term_to_iovec([:compressed])
        |> IO.iodata_to_binary()
        |> Base.encode64()

      payload_size = byte_size(replay_info)

      if payload_size <= 10_000 do
        Sentry.Context.set_extra_context(%{
          debug_replay_info: replay_info,
          debug_replay_info_size: payload_size
        })
      else
        Sentry.Context.set_extra_context(%{
          debug_replay_info: :too_large,
          debug_replay_info_size: payload_size
        })
      end

      :ok
    end
  end

  def super_admin? do
    context = Sentry.Context.get_all()

    case context[:user] do
      %{super_admin?: true} ->
        true

      _ ->
        false
    end
  end

  def track_query(query, label) do
    queries = get_queries_from_context()

    Sentry.Context.set_extra_context(%{
      queries: [%{label => query} | queries]
    })
  end

  def carry_over_context(sentry_ctx) do
    Sentry.Context.set_user_context(sentry_ctx[:user])
    Sentry.Context.set_request_context(sentry_ctx[:request])

    Sentry.Context.set_extra_context(%{
      domain: sentry_ctx[:extra][:domain],
      site_id: sentry_ctx[:extra][:site_id]
    })
  end

  def get_queries_from_context(context \\ Sentry.Context.get_all()) do
    get_in(context, [:extra, :queries]) || []
  end

  @spec deserialize(String.t()) :: any()
  def deserialize(replay_info) do
    replay_info
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end
end
