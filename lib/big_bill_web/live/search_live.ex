defmodule BigBillWeb.SearchLive do
  use BigBillWeb, :live_view

  alias BigBill.Search

  @impl true
  def mount(_params, _session, socket) do
    unless Search.index_exists?() do
      Search.build_index()
    end

    socket =
      socket
      |> assign(:page_title, "Search")
      |> assign(:query, "")
      |> assign(:active_tab, :all)
      |> assign(:results, [])
      |> assign(:result_count, 0)
      |> assign(:facet_counts, %{bill: 0, analysis: 0, graph_node: 0, document: 0})
      |> assign(:rebuilding, false)
      |> assign(:modal_open, false)
      |> assign(:modal_content, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, run_search(socket, String.trim(query), socket.assigns.active_tab)}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) do
    tab = parse_tab(tab)
    {:noreply, run_search(socket, socket.assigns.query, tab)}
  end

  def handle_event("rebuild_index", _params, socket) do
    socket = assign(socket, :rebuilding, true)
    send(self(), :do_rebuild)
    {:noreply, socket}
  end

  def handle_event("open_result", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    result = Enum.at(socket.assigns.results, index)

    if result do
      content = Search.get_full_content(result)
      {:noreply, socket |> assign(:modal_open, true) |> assign(:modal_content, content)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, socket |> assign(:modal_open, false) |> assign(:modal_content, nil)}
  end

  @impl true
  def handle_info(:do_rebuild, socket) do
    Search.build_index()

    socket =
      socket
      |> assign(:rebuilding, false)
      |> run_search(socket.assigns.query, socket.assigns.active_tab)

    {:noreply, socket}
  end

  defp run_search(socket, query, tab) do
    if String.length(query) >= 2 do
      facet = if tab == :all, do: :all, else: tab
      results = Search.search(query, facet)
      counts = Search.facet_counts(query)
      total = counts |> Map.values() |> Enum.sum()

      socket
      |> assign(:query, query)
      |> assign(:active_tab, tab)
      |> assign(:results, results)
      |> assign(:result_count, if(tab == :all, do: total, else: Map.get(counts, tab, 0)))
      |> assign(:facet_counts, counts)
    else
      socket
      |> assign(:query, query)
      |> assign(:active_tab, tab)
      |> assign(:results, [])
      |> assign(:result_count, 0)
      |> assign(:facet_counts, %{bill: 0, analysis: 0, graph_node: 0, document: 0})
    end
  end

  defp parse_tab("bill"), do: :bill
  defp parse_tab("analysis"), do: :analysis
  defp parse_tab("graph_node"), do: :graph_node
  defp parse_tab("document"), do: :document
  defp parse_tab(_), do: :all

  defp tab_label(:all), do: "All"
  defp tab_label(:bill), do: "Bill Text"
  defp tab_label(:analysis), do: "Analysis"
  defp tab_label(:graph_node), do: "Graph Nodes"
  defp tab_label(:document), do: "Documents"

  defp tab_count(:all, counts), do: counts |> Map.values() |> Enum.sum()
  defp tab_count(tab, counts), do: Map.get(counts, tab, 0)

  defp source_badge_class(:bill), do: "bg-blue-100 text-blue-800"
  defp source_badge_class(:analysis), do: "bg-green-100 text-green-800"
  defp source_badge_class(:graph_node), do: "bg-purple-100 text-purple-800"
  defp source_badge_class(:document), do: "bg-amber-100 text-amber-800"
  defp source_badge_class(_), do: "bg-gray-100 text-gray-800"

  defp source_label(:bill), do: "Bill"
  defp source_label(:analysis), do: "Analysis"
  defp source_label(:graph_node), do: "Graph"
  defp source_label(:document), do: "Document"
  defp source_label(_), do: "Other"

  defp modal_source_label(:bill), do: "Legislative Text"
  defp modal_source_label(:analysis), do: "Analysis"
  defp modal_source_label(:graph_node), do: "Decision Graph Node"
  defp modal_source_label(:document), do: "Attached Document"
  defp modal_source_label(_), do: "Content"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-6xl mx-auto px-4 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <.link navigate={~p"/"} class="text-sm text-blue-600 hover:text-blue-800 mb-2 inline-block">
              &larr; Back to Dashboard
            </.link>
            <h1 class="text-2xl font-bold text-gray-900">Full-Text Search</h1>
          </div>
          <button
            phx-click="rebuild_index"
            disabled={@rebuilding}
            class="text-sm px-3 py-1.5 rounded border border-gray-300 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <%= if @rebuilding, do: "Rebuilding...", else: "Rebuild Index" %>
          </button>
        </div>

        <form phx-change="search" class="mb-4">
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Search bill text, analysis, graph nodes, documents..."
            class="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 text-lg"
            phx-debounce="300"
            autofocus
          />
        </form>

        <%!-- Facet tabs --%>
        <div :if={@query != "" && String.length(@query) >= 2} class="flex gap-1 mb-4 border-b border-gray-200">
          <button
            :for={tab <- [:all, :bill, :analysis, :graph_node, :document]}
            phx-click="set_tab"
            phx-value-tab={tab}
            class={[
              "px-3 py-2 text-sm font-medium rounded-t-md transition-colors -mb-px",
              if(@active_tab == tab,
                do: "border border-gray-200 border-b-white bg-white text-blue-600",
                else: "text-gray-500 hover:text-gray-700 hover:bg-gray-50"
              )
            ]}
          >
            {tab_label(tab)}
            <span class={[
              "ml-1.5 text-xs font-normal px-1.5 py-0.5 rounded-full",
              if(@active_tab == tab, do: "bg-blue-100 text-blue-700", else: "bg-gray-100 text-gray-600")
            ]}>
              {tab_count(tab, @facet_counts)}
            </span>
          </button>
        </div>

        <div :if={@query != "" && String.length(@query) >= 2 && @result_count > 0} class="text-sm text-gray-500 mb-4">
          {if length(@results) < @result_count, do: "Showing #{length(@results)} of #{@result_count}", else: "#{@result_count}"} results
        </div>

        <div :if={@query != "" && String.length(@query) >= 2 && @results == []} class="py-12 text-center">
          <div class="text-gray-400 text-lg mb-2">No results found</div>
          <div class="text-gray-400 text-sm">Try different keywords or check another tab</div>
        </div>

        <%!-- Results list — click to open modal --%>
        <div class="space-y-3">
          <button
            :for={{result, index} <- Enum.with_index(@results)}
            phx-click="open_result"
            phx-value-index={index}
            class="w-full text-left bg-white rounded-lg border border-gray-200 px-4 py-3 hover:border-blue-300 hover:shadow-sm transition-all cursor-pointer"
          >
            <div class="flex items-start gap-3">
              <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium mt-0.5 shrink-0 #{source_badge_class(result.source)}"}>
                {source_label(result.source)}
              </span>
              <div class="flex-1 min-w-0">
                <div class="font-medium text-gray-900 truncate">
                  {result.title}
                </div>
                <div :if={result.section_number} class="text-xs text-gray-500 mt-0.5">
                  Section {result.section_number}
                </div>
                <div class="text-sm text-gray-600 mt-1 line-clamp-2">
                  {raw(result.snippet)}
                </div>
              </div>
              <span class="text-gray-300 mt-1 shrink-0">
                <.icon name="hero-chevron-right" class="w-5 h-5" />
              </span>
            </div>
          </button>
        </div>

        <div :if={@query != "" && String.length(@query) < 2} class="py-12 text-center text-gray-400">
          Type at least 2 characters to search
        </div>
      </div>

      <%!-- Modal overlay --%>
      <div
        :if={@modal_open && @modal_content}
        class="fixed inset-0 z-50 flex items-start justify-center pt-8 pb-8"
        phx-window-keydown="close_modal"
        phx-key="Escape"
      >
        <%!-- Backdrop --%>
        <div class="absolute inset-0 bg-black/50" phx-click="close_modal"></div>

        <%!-- Modal panel --%>
        <div class="relative bg-white rounded-xl shadow-2xl w-full max-w-4xl mx-4 max-h-[90vh] flex flex-col">
          <%!-- Header --%>
          <div class="flex items-start justify-between px-6 py-4 border-b border-gray-200 shrink-0">
            <div class="flex-1 min-w-0 pr-4">
              <div class="flex items-center gap-2 mb-1">
                <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{source_badge_class(@modal_content.source)}"}>
                  {modal_source_label(@modal_content.source)}
                </span>
                <span :if={@modal_content.section_number} class="text-xs text-gray-500">
                  Section {@modal_content.section_number}
                </span>
                <span :if={@modal_content.node_id} class="text-xs text-gray-500">
                  Node #{@modal_content.node_id}
                </span>
              </div>
              <h2 class="text-lg font-bold text-gray-900 leading-tight">
                {@modal_content.title}
              </h2>
              <%!-- Meta tags --%>
              <div :if={@modal_content.meta != %{}} class="flex flex-wrap gap-1.5 mt-2">
                <span
                  :for={{key, val} <- @modal_content.meta}
                  :if={val}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs bg-gray-100 text-gray-600"
                >
                  <span class="font-medium text-gray-500 mr-1">{key}:</span> {val}
                </span>
              </div>
            </div>
            <button phx-click="close_modal" class="p-1 rounded-md hover:bg-gray-100 text-gray-400 hover:text-gray-600 shrink-0">
              <.icon name="hero-x-mark" class="w-6 h-6" />
            </button>
          </div>

          <%!-- Body — scrollable --%>
          <div class="flex-1 overflow-y-auto px-6 py-4">
            <%= if @modal_content.source == :bill do %>
              <pre class="text-sm font-mono text-gray-800 whitespace-pre-wrap leading-relaxed">{@modal_content.content}</pre>
            <% else %>
              <div class="prose prose-sm max-w-none text-gray-800 whitespace-pre-wrap">{@modal_content.content}</div>
            <% end %>
          </div>

          <%!-- Footer --%>
          <div class="flex items-center justify-between px-6 py-3 border-t border-gray-200 bg-gray-50 rounded-b-xl shrink-0">
            <div class="text-xs text-gray-400">
              <%= if @modal_content.source == :bill && @modal_content.section_number do %>
                {String.length(@modal_content.content)} characters
              <% end %>
            </div>
            <div class="flex gap-2">
              <.link
                :if={@modal_content.source == :bill && @modal_content.section_number}
                navigate={~p"/section/#{@modal_content.section_number}"}
                class="text-sm px-3 py-1.5 rounded bg-blue-600 text-white hover:bg-blue-700 transition-colors"
              >
                Open Full Page
              </.link>
              <button phx-click="close_modal" class="text-sm px-3 py-1.5 rounded border border-gray-300 hover:bg-gray-100 transition-colors">
                Close
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
