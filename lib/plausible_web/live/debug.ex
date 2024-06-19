defmodule PlausibleWeb.Live.Debug do
  use PlausibleWeb, :live_view
  use Phoenix.HTML

  import PlausibleWeb.Components.Generic
  import Ecto.Query

  def mount(
        :not_mounted_at_router,
        %{"site_id" => site_id},
        socket
      )
      when is_integer(site_id) do
    socket = assign(socket, logs: [], site_id: site_id)
    {:ok, socket}
  end

  def query(site_id) do
    from ql in "query_log",
      prefix: "system",
      where:
        ql.type == 2 and
          fragment("JSONExtractString(?,'site_id') = '?'", ql.log_comment, ^site_id) and
          fragment(
            "has(tables, concat(?, '.events_v2')) OR has(tables, concat(?, '.sessions_v2'))",
            ql.current_database,
            ql.current_database
          ),
      order_by: [desc: ql.event_time],
      select: %{
        url: fragment("JSONExtractString(?, 'url')", ql.log_comment),
        timestamp: ql.event_time,
        query: ql.query,
        label: fragment("JSONExtractString(?, 'label')", ql.log_comment),
        duration: ql.query_duration_ms,
        rows: ql.read_rows,
        bytes: ql.read_bytes
      },
      limit: 50
  end

  def get_logs(site_id) do
    q = query(site_id)

    Plausible.ClickhouseRepo.all(q)
  end

  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-white " x-on:click="debug = false"></div>
    <div class="fixed inset-0 z-10 overflow-y-auto container bg-white">
      <div class="sticky top-0 z-50 bg-white pb-8 border-gray-200 border-b">
        <div class="rounded-full p-8">
          <input
            type="text"
            name="filter-text"
            id="filter-text"
            class="shadow-sm dark:bg-gray-900 dark:text-gray-300 focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 dark:border-gray-500 rounded-md dark:bg-gray-800"
            placeholder="Filter queries"
          />
        </div>
        <fieldset class="px-8">
          <div class="space-y-5">
            <div class="relative flex items-start">
              <div class="flex h-6 items-center">
                <input
                  id="comments"
                  aria-describedby="comments-description"
                  name="comments"
                  type="checkbox"
                  class="h-4 w-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-600"
                />
              </div>
              <div class="ml-3 text-sm leading-6">
                <label for="comments" class="font-medium text-gray-900">
                  Show queries made by other users
                </label>
              </div>
            </div>
          </div>
        </fieldset>

        <fieldset class="m-8">
          <.button phx-click="search">Search</.button>
        </fieldset>
      </div>

      <div :for={row <- @logs} class="m-8 p-8 border-b border-gray-200  bg-white shadow-lg rounded-lg">
        <div class="text-s mb-4 font-bold inline-flex space-x-4 border-b pb-4 w-full">
          <div class="py-1">
            <%= row.timestamp %>
          </div>
          <div class="py-1">
            Duration: <%= row.duration %> ms
          </div>
          <div class="py-1">
            Rows: <%= PlausibleWeb.StatsView.large_number_format(row.rows) %> (<%= PlausibleWeb.StatsView.large_number_format(
              row.bytes
            ) %> bytes)
          </div>
          <div class={label_style(row.label)}>
            <%= row.label %>
          </div>
        </div>
        <div class="font-mono mt-4">
          <code class="break-all">
            <%= row.query %>
          </code>
          <br />
        </div>
        <div class="text-right mt-8 flex">
          <div class="flex-none">
            <.styled_link href={row.url} new_tab={true}>Visit URL</.styled_link>
          </div>
          <.styled_link class="flex-1">
            <span class="inline-flex">
              Copy to Clipboard
              <span id="copy-base-icon">
                <Heroicons.document_duplicate class="h-4 w-4 ml-2 mt-1" />
              </span>
            </span>
          </.styled_link>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("search", _, socket) do
    {:noreply, assign(socket, logs: get_logs(socket.assigns.site_id))}
  end

  defp label_style(nil), do: nil

  defp label_style(""), do: nil

  defp label_style(some) do
    styles = [
      "bg-red-400",
      "bg-blue-400",
      "bg-green-400",
      "bg-gray-400",
      "bg-yellow-800"
    ]

    pick = :erlang.phash2(some, length(styles))

    "#{Enum.at(styles, pick)} text-white px-2 py-1 rounded-md"
  end
end
