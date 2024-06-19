defmodule Plausible.ClickhouseRepo do
  use Ecto.Repo,
    otp_app: :plausible,
    adapter: Ecto.Adapters.ClickHouse,
    read_only: true

  require Logger

  defmacro __using__(_) do
    quote do
      alias Plausible.ClickhouseRepo
      import Ecto
      import Ecto.Query, only: [from: 1, from: 2]
    end
  end

  @impl Ecto.Repo
  def prepare_query(_operation, query, opts) do
    {query, include_log_comment(opts)}
  end

  @task_timeout 60_000
  def parallel_tasks(queries, opts \\ []) do
    otel_ctx = OpenTelemetry.Ctx.get_current()
    sentry_ctx = Sentry.Context.get_all()

    execute_with_tracing = fn fun ->
      Plausible.DebugReplayInfo.carry_over_context(sentry_ctx)
      OpenTelemetry.Ctx.attach(otel_ctx)
      result = fun.()
      {Sentry.Context.get_all(), result}
    end

    max_concurrency = Keyword.get(opts, :max_concurrency, 3)

    Task.async_stream(queries, execute_with_tracing,
      max_concurrency: max_concurrency,
      timeout: @task_timeout
    )
    |> Enum.to_list()
    |> Keyword.values()
    |> Enum.map(fn {sentry_ctx, result} ->
      set_sentry_context(sentry_ctx)
      result
    end)
  end

  defp set_sentry_context(previous_sentry_ctx) do
    Plausible.DebugReplayInfo.carry_over_context(previous_sentry_ctx)
    previous_queries = Plausible.DebugReplayInfo.get_queries_from_context(previous_sentry_ctx)
    current_queries = Plausible.DebugReplayInfo.get_queries_from_context()

    Sentry.Context.set_extra_context(%{
      queries: previous_queries ++ current_queries
    })
  end

  defp include_log_comment(opts) do
    sentry_context = Sentry.Context.get_all()

    log_comment =
      %{
        user_id: sentry_context[:user][:id],
        label: opts[:label] || "unlabelled",
        url: sentry_context[:request][:url],
        domain: sentry_context[:extra][:domain],
        site_id: sentry_context[:extra][:site_id],
        metadata: opts[:metadata] || %{}
      }

    case Jason.encode(log_comment) do
      {:ok, encoded} ->
        setting = {:log_comment, encoded}
        Keyword.update(opts, :settings, [setting], fn settings -> [setting | settings] end)

      {:error, _} ->
        Logger.error("Failed to include log comment: #{inspect(log_comment)}")
        opts
    end
  end
end
