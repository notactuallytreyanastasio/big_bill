defmodule BigBillWeb.DrilldownLive do
  use BigBillWeb, :live_view

  alias BigBill.Search
  alias BigBill.Legislation.Parser

  @title_boundaries Parser.title_boundaries()

  @analysis_files [
    "title_01_agriculture.md",
    "title_02_armed_services.md",
    "title_03_banking.md",
    "title_04_commerce.md",
    "title_05_energy.md",
    "title_06_environment.md",
    "title_07a_tax_ch1_ch2.md",
    "title_07b_tax_ch3_ch4.md",
    "title_07c_green_deal_ch5_ch6.md",
    "title_07d_medicaid.md",
    "title_07e_medicare_aca_debt.md",
    "title_08_help.md",
    "title_09_homeland.md",
    "title_10_judiciary.md",
    "cross_provision_links.md",
    "externalities_and_oddities.md",
    "power_map.md"
  ]

  @filter_types [
    {:contains, "Contains"},
    {:not_contains, "Does NOT contain"},
    {:exact_phrase, "Exact phrase"},
    {:near, "Near (within N words)"},
    {:field, "Field"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    unless Search.index_exists?() do
      Search.build_index()
    end

    socket =
      socket
      |> assign(:page_title, "Drilldown Search")
      |> assign(:filters, [default_filter()])
      |> assign(:scopes, [])
      |> assign(:scope_titles, MapSet.new())
      |> assign(:scope_all_titles, false)
      |> assign(:scope_analysis_files, MapSet.new())
      |> assign(:scope_all_analysis, false)
      |> assign(:scope_graph_types, MapSet.new())
      |> assign(:scope_all_graph, false)
      |> assign(:results, [])
      |> assign(:result_count, 0)
      |> assign(:searching, false)
      |> assign(:sidebar_open, true)
      |> assign(:related_panel, nil)
      |> assign(:filter_types, @filter_types)
      |> assign(:title_boundaries, @title_boundaries)
      |> assign(:analysis_files, @analysis_files)

    {:ok, socket}
  end

  # -------------------------------------------------------------------
  # Events
  # -------------------------------------------------------------------

  @impl true
  def handle_event("add_filter", _params, socket) do
    filters = socket.assigns.filters ++ [default_filter()]
    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("remove_filter", %{"id" => id}, socket) do
    filters = Enum.reject(socket.assigns.filters, &(&1.id == id))
    filters = if filters == [], do: [default_filter()], else: filters
    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("update_filter_type", %{"id" => id, "type" => type}, socket) do
    type = String.to_existing_atom(type)

    filters =
      Enum.map(socket.assigns.filters, fn f ->
        if f.id == id, do: %{f | type: type}, else: f
      end)

    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("update_filter_value", %{"id" => id, "value" => value}, socket) do
    filters =
      Enum.map(socket.assigns.filters, fn f ->
        if f.id == id, do: %{f | value: value}, else: f
      end)

    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("update_filter_near_n", %{"id" => id, "n" => n}, socket) do
    n = case Integer.parse(n) do
      {val, _} -> max(1, val)
      :error -> 5
    end

    filters =
      Enum.map(socket.assigns.filters, fn f ->
        if f.id == id, do: %{f | near_n: n}, else: f
      end)

    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("toggle_connector", %{"id" => id}, socket) do
    filters =
      Enum.map(socket.assigns.filters, fn f ->
        if f.id == id do
          %{f | connector: if(f.connector == :and, do: :or, else: :and)}
        else
          f
        end
      end)

    {:noreply, assign(socket, :filters, filters)}
  end

  # Scope toggles
  def handle_event("toggle_all_titles", _params, socket) do
    new_val = !socket.assigns.scope_all_titles

    socket =
      socket
      |> assign(:scope_all_titles, new_val)
      |> assign(:scope_titles, if(new_val, do: MapSet.new(Enum.map(@title_boundaries, & &1.num)), else: MapSet.new()))

    {:noreply, socket}
  end

  def handle_event("toggle_title", %{"num" => num}, socket) do
    num = String.to_integer(num)
    titles = socket.assigns.scope_titles

    titles =
      if MapSet.member?(titles, num),
        do: MapSet.delete(titles, num),
        else: MapSet.put(titles, num)

    all = MapSet.size(titles) == length(@title_boundaries)

    socket =
      socket
      |> assign(:scope_titles, titles)
      |> assign(:scope_all_titles, all)

    {:noreply, socket}
  end

  def handle_event("toggle_all_analysis", _params, socket) do
    new_val = !socket.assigns.scope_all_analysis

    socket =
      socket
      |> assign(:scope_all_analysis, new_val)
      |> assign(:scope_analysis_files, if(new_val, do: MapSet.new(@analysis_files), else: MapSet.new()))

    {:noreply, socket}
  end

  def handle_event("toggle_analysis_file", %{"file" => file}, socket) do
    files = socket.assigns.scope_analysis_files

    files =
      if MapSet.member?(files, file),
        do: MapSet.delete(files, file),
        else: MapSet.put(files, file)

    all = MapSet.size(files) == length(@analysis_files)

    socket =
      socket
      |> assign(:scope_analysis_files, files)
      |> assign(:scope_all_analysis, all)

    {:noreply, socket}
  end

  def handle_event("toggle_all_graph", _params, socket) do
    new_val = !socket.assigns.scope_all_graph

    socket =
      socket
      |> assign(:scope_all_graph, new_val)
      |> assign(:scope_graph_types, if(new_val, do: MapSet.new(~w(action observation goal decision option outcome)), else: MapSet.new()))

    {:noreply, socket}
  end

  def handle_event("toggle_graph_type", %{"type" => type}, socket) do
    types = socket.assigns.scope_graph_types

    types =
      if MapSet.member?(types, type),
        do: MapSet.delete(types, type),
        else: MapSet.put(types, type)

    socket = assign(socket, :scope_graph_types, types)
    {:noreply, socket}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  def handle_event("search", _params, socket) do
    socket = assign(socket, :searching, true)
    send(self(), :execute_search)
    {:noreply, socket}
  end

  def handle_event("find_related", %{"section" => section_number}, socket) do
    # Search for cross-references to this section
    related_results = Search.search(section_number, :all) |> Enum.take(8)

    panel = %{
      source_section: section_number,
      related: related_results
    }

    {:noreply, assign(socket, :related_panel, panel)}
  end

  def handle_event("close_related", _params, socket) do
    {:noreply, assign(socket, :related_panel, nil)}
  end

  @impl true
  def handle_info(:execute_search, socket) do
    query = build_query_string(socket.assigns.filters)
    facets = determine_facets(socket.assigns)

    results =
      if String.trim(query) == "" do
        []
      else
        facets
        |> Enum.flat_map(fn facet -> Search.search(query, facet) end)
        |> Enum.uniq_by(fn r -> {r.source, r.section_number, r.title} end)
        |> apply_negative_filters(socket.assigns.filters)
        |> Enum.sort_by(& &1.rank)
        |> Enum.take(100)
      end

    socket =
      socket
      |> assign(:results, results)
      |> assign(:result_count, length(results))
      |> assign(:searching, false)

    {:noreply, socket}
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp default_filter do
    %{
      id: "f#{System.unique_integer([:positive])}",
      type: :contains,
      value: "",
      connector: :and,
      near_n: 5
    }
  end

  defp build_query_string(filters) do
    filters
    |> Enum.filter(&(&1.type in [:contains, :exact_phrase, :near] and &1.value != ""))
    |> Enum.map(fn filter ->
      case filter.type do
        :exact_phrase -> "\"#{filter.value}\""
        :near -> filter.value
        :contains -> filter.value
      end
    end)
    |> Enum.join(" ")
  end

  defp apply_negative_filters(results, filters) do
    negatives =
      filters
      |> Enum.filter(&(&1.type == :not_contains and &1.value != ""))
      |> Enum.map(&String.downcase(&1.value))

    if negatives == [] do
      results
    else
      Enum.reject(results, fn result ->
        text = String.downcase("#{result.title} #{result.snippet}")
        Enum.any?(negatives, fn neg -> String.contains?(text, neg) end)
      end)
    end
  end

  defp determine_facets(assigns) do
    has_titles = MapSet.size(assigns.scope_titles) > 0
    has_analysis = MapSet.size(assigns.scope_analysis_files) > 0
    has_graph = MapSet.size(assigns.scope_graph_types) > 0

    cond do
      !has_titles and !has_analysis and !has_graph ->
        [:all]

      true ->
        facets = []
        facets = if has_titles, do: facets ++ [:bill], else: facets
        facets = if has_analysis, do: facets ++ [:analysis], else: facets
        facets = if has_graph, do: facets ++ [:graph_node], else: facets
        if facets == [], do: [:all], else: facets
    end
  end

  defp to_roman(1), do: "I"
  defp to_roman(2), do: "II"
  defp to_roman(3), do: "III"
  defp to_roman(4), do: "IV"
  defp to_roman(5), do: "V"
  defp to_roman(6), do: "VI"
  defp to_roman(7), do: "VII"
  defp to_roman(8), do: "VIII"
  defp to_roman(9), do: "IX"
  defp to_roman(10), do: "X"
  defp to_roman(n), do: Integer.to_string(n)

  defp source_badge_class(:bill), do: "bg-blue-100 text-blue-800 border-blue-200"
  defp source_badge_class(:analysis), do: "bg-green-100 text-green-800 border-green-200"
  defp source_badge_class(:graph_node), do: "bg-purple-100 text-purple-800 border-purple-200"
  defp source_badge_class(:document), do: "bg-amber-100 text-amber-800 border-amber-200"

  defp source_label(:bill), do: "Bill"
  defp source_label(:analysis), do: "Analysis"
  defp source_label(:graph_node), do: "Graph"
  defp source_label(:document), do: "Document"

  defp active_filter_count(filters) do
    Enum.count(filters, &(&1.value != ""))
  end

  defp active_scope_count(assigns) do
    MapSet.size(assigns.scope_titles) +
      MapSet.size(assigns.scope_analysis_files) +
      MapSet.size(assigns.scope_graph_types)
  end

  defp analysis_display_name(filename) do
    filename
    |> String.replace(~r/\.md$/, "")
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # -------------------------------------------------------------------
  # Render
  # -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-[1600px] mx-auto px-4 py-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-6">
          <div>
            <.link navigate={~p"/"} class="text-sm text-blue-600 hover:text-blue-800 mb-1 inline-block">
              &larr; Back to Dashboard
            </.link>
            <h1 class="text-2xl font-bold text-gray-900">Drilldown Search</h1>
            <p class="text-sm text-gray-500 mt-1">Build complex queries with visual filters and scoped search</p>
          </div>
          <.link navigate={~p"/search"} class="text-sm px-3 py-1.5 rounded border border-gray-300 hover:bg-gray-50 transition-colors">
            Simple Search
          </.link>
        </div>

        <div class="flex gap-6">
          <%!-- Sidebar: Scope Panel --%>
          <aside class={[
            "shrink-0 transition-all duration-300 overflow-hidden",
            if(@sidebar_open, do: "w-64", else: "w-0")
          ]}>
            <div class="w-64 bg-white rounded-lg border border-gray-200 shadow-sm overflow-hidden">
              <div class="px-4 py-3 bg-gray-50 border-b border-gray-200">
                <h2 class="text-sm font-semibold text-gray-700 uppercase tracking-wider">Search Scope</h2>
              </div>
              <div class="p-3 max-h-[calc(100vh-280px)] overflow-y-auto space-y-4">
                <%!-- Titles --%>
                <div>
                  <label class="flex items-center gap-2 cursor-pointer group mb-2">
                    <input
                      type="checkbox"
                      checked={@scope_all_titles}
                      phx-click="toggle_all_titles"
                      class="rounded border-gray-300 text-blue-600 focus:ring-blue-500 h-4 w-4"
                    />
                    <span class="text-sm font-semibold text-gray-700 group-hover:text-gray-900">All Titles</span>
                  </label>
                  <div class="ml-6 space-y-1">
                    <label
                      :for={tb <- @title_boundaries}
                      class="flex items-center gap-2 cursor-pointer group"
                    >
                      <input
                        type="checkbox"
                        checked={MapSet.member?(@scope_titles, tb.num)}
                        phx-click="toggle_title"
                        phx-value-num={tb.num}
                        class="rounded border-gray-300 text-blue-600 focus:ring-blue-500 h-3.5 w-3.5"
                      />
                      <span class="text-xs text-gray-600 group-hover:text-gray-800 leading-tight">
                        Title {to_roman(tb.num)} -- {tb.name}
                      </span>
                    </label>
                  </div>
                </div>

                <%!-- Analysis Files --%>
                <div class="border-t border-gray-100 pt-3">
                  <label class="flex items-center gap-2 cursor-pointer group mb-2">
                    <input
                      type="checkbox"
                      checked={@scope_all_analysis}
                      phx-click="toggle_all_analysis"
                      class="rounded border-gray-300 text-emerald-600 focus:ring-emerald-500 h-4 w-4"
                    />
                    <span class="text-sm font-semibold text-gray-700 group-hover:text-gray-900">All Analysis Files</span>
                  </label>
                  <div class="ml-6 space-y-1">
                    <label
                      :for={file <- @analysis_files}
                      class="flex items-center gap-2 cursor-pointer group"
                    >
                      <input
                        type="checkbox"
                        checked={MapSet.member?(@scope_analysis_files, file)}
                        phx-click="toggle_analysis_file"
                        phx-value-file={file}
                        class="rounded border-gray-300 text-emerald-600 focus:ring-emerald-500 h-3.5 w-3.5"
                      />
                      <span class="text-xs text-gray-600 group-hover:text-gray-800 truncate leading-tight">
                        {analysis_display_name(file)}
                      </span>
                    </label>
                  </div>
                </div>

                <%!-- Graph Nodes --%>
                <div class="border-t border-gray-100 pt-3">
                  <label class="flex items-center gap-2 cursor-pointer group mb-2">
                    <input
                      type="checkbox"
                      checked={@scope_all_graph}
                      phx-click="toggle_all_graph"
                      class="rounded border-gray-300 text-purple-600 focus:ring-purple-500 h-4 w-4"
                    />
                    <span class="text-sm font-semibold text-gray-700 group-hover:text-gray-900">Graph Nodes</span>
                  </label>
                  <div class="ml-6 space-y-1">
                    <label
                      :for={type <- ~w(action observation goal decision option outcome)}
                      class="flex items-center gap-2 cursor-pointer group"
                    >
                      <input
                        type="checkbox"
                        checked={MapSet.member?(@scope_graph_types, type)}
                        phx-click="toggle_graph_type"
                        phx-value-type={type}
                        class="rounded border-gray-300 text-purple-600 focus:ring-purple-500 h-3.5 w-3.5"
                      />
                      <span class="text-xs text-gray-600 group-hover:text-gray-800 capitalize">
                        {type}s only
                      </span>
                    </label>
                  </div>
                </div>
              </div>
            </div>
          </aside>

          <%!-- Main content --%>
          <div class="flex-1 min-w-0">
            <%!-- Toggle sidebar button --%>
            <button
              phx-click="toggle_sidebar"
              class="mb-3 text-xs text-gray-500 hover:text-gray-700 flex items-center gap-1 transition-colors"
            >
              <svg :if={@sidebar_open} xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 19l-7-7 7-7m8 14l-7-7 7-7" />
              </svg>
              <svg :if={!@sidebar_open} xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 5l7 7-7 7M5 5l7 7-7 7" />
              </svg>
              {if @sidebar_open, do: "Hide scope panel", else: "Show scope panel"}
            </button>

            <%!-- Query Builder --%>
            <div class="bg-white rounded-lg border border-gray-200 shadow-sm p-4 mb-4">
              <div class="flex items-center justify-between mb-3">
                <h2 class="text-sm font-semibold text-gray-700 uppercase tracking-wider">Query Builder</h2>
                <div class="flex items-center gap-2 text-xs text-gray-400">
                  <span :if={active_filter_count(@filters) > 0}>
                    {active_filter_count(@filters)} active filter(s)
                  </span>
                  <span :if={active_scope_count(assigns) > 0} class="border-l border-gray-300 pl-2">
                    {active_scope_count(assigns)} scope(s)
                  </span>
                </div>
              </div>

              <div class="space-y-2">
                <div :for={{filter, idx} <- Enum.with_index(@filters)} class="group">
                  <%!-- Connector between filters --%>
                  <div :if={idx > 0} class="flex justify-center my-1">
                    <button
                      phx-click="toggle_connector"
                      phx-value-id={filter.id}
                      class={[
                        "px-3 py-0.5 rounded-full text-xs font-semibold transition-colors cursor-pointer",
                        if(filter.connector == :and,
                          do: "bg-blue-50 text-blue-600 hover:bg-blue-100",
                          else: "bg-orange-50 text-orange-600 hover:bg-orange-100"
                        )
                      ]}
                    >
                      {if filter.connector == :and, do: "AND", else: "OR"}
                    </button>
                  </div>

                  <%!-- Filter row --%>
                  <div class="flex items-center gap-2 bg-gray-50 rounded-lg p-2 border border-gray-100 group-hover:border-gray-300 transition-colors">
                    <%!-- Type dropdown --%>
                    <select
                      phx-change="update_filter_type"
                      phx-value-id={filter.id}
                      name="type"
                      class="text-sm border-gray-300 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 bg-white py-1.5 pr-8"
                    >
                      <option :for={{val, label} <- @filter_types} value={val} selected={filter.type == val}>
                        {label}
                      </option>
                    </select>

                    <%!-- Value input --%>
                    <input
                      type="text"
                      value={filter.value}
                      phx-change="update_filter_value"
                      phx-value-id={filter.id}
                      name="value"
                      placeholder={filter_placeholder(filter.type)}
                      phx-debounce="200"
                      class="flex-1 text-sm border-gray-300 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 py-1.5"
                    />

                    <%!-- Near N input --%>
                    <div :if={filter.type == :near} class="flex items-center gap-1">
                      <span class="text-xs text-gray-500 whitespace-nowrap">within</span>
                      <input
                        type="number"
                        value={filter.near_n}
                        phx-change="update_filter_near_n"
                        phx-value-id={filter.id}
                        name="n"
                        min="1"
                        max="50"
                        class="w-14 text-sm border-gray-300 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 py-1.5 text-center"
                      />
                      <span class="text-xs text-gray-500 whitespace-nowrap">words</span>
                    </div>

                    <%!-- Remove button --%>
                    <button
                      phx-click="remove_filter"
                      phx-value-id={filter.id}
                      class="p-1 text-gray-400 hover:text-red-500 hover:bg-red-50 rounded transition-colors"
                      title="Remove filter"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </div>
                </div>
              </div>

              <%!-- Actions --%>
              <div class="flex items-center justify-between mt-3 pt-3 border-t border-gray-100">
                <button
                  phx-click="add_filter"
                  class="text-sm text-blue-600 hover:text-blue-800 font-medium flex items-center gap-1 transition-colors"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
                  </svg>
                  Add Filter
                </button>

                <button
                  phx-click="search"
                  disabled={@searching or active_filter_count(@filters) == 0}
                  class={[
                    "px-5 py-2 rounded-lg text-sm font-semibold transition-all",
                    if(active_filter_count(@filters) > 0,
                      do: "bg-blue-600 text-white hover:bg-blue-700 shadow-sm hover:shadow",
                      else: "bg-gray-200 text-gray-400 cursor-not-allowed"
                    )
                  ]}
                >
                  <%= if @searching do %>
                    <span class="flex items-center gap-2">
                      <svg class="animate-spin h-4 w-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                      </svg>
                      Searching...
                    </span>
                  <% else %>
                    Search
                  <% end %>
                </button>
              </div>
            </div>

            <%!-- Results area --%>
            <div class="flex gap-4">
              <%!-- Results list --%>
              <div class={[
                "min-w-0 transition-all duration-300",
                if(@related_panel, do: "flex-1", else: "w-full")
              ]}>
                <%!-- Result count --%>
                <div :if={@result_count > 0} class="text-sm text-gray-500 mb-3">
                  {if @result_count == 100, do: "Showing top 100", else: "#{@result_count}"} results
                </div>

                <%!-- Empty state --%>
                <div :if={@results == [] and !@searching and active_filter_count(@filters) > 0} class="py-16 text-center bg-white rounded-lg border border-gray-200">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-12 w-12 mx-auto text-gray-300 mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
                  </svg>
                  <div class="text-gray-400 text-lg mb-1">Ready to search</div>
                  <div class="text-gray-400 text-sm">Add filters above and click Search</div>
                </div>

                <%!-- Initial state --%>
                <div :if={@results == [] and active_filter_count(@filters) == 0} class="py-16 text-center bg-white rounded-lg border border-gray-200">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-12 w-12 mx-auto text-gray-300 mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M3 4a1 1 0 011-1h16a1 1 0 011 1v2.586a1 1 0 01-.293.707l-6.414 6.414a1 1 0 00-.293.707V17l-4 4v-6.586a1 1 0 00-.293-.707L3.293 7.293A1 1 0 013 6.586V4z" />
                  </svg>
                  <div class="text-gray-400 text-lg mb-1">Build your query</div>
                  <div class="text-gray-400 text-sm">Use the filter blocks above to construct a search query.<br/>Select scopes on the left to narrow results.</div>
                </div>

                <%!-- Result cards --%>
                <div class="space-y-3">
                  <div
                    :for={result <- @results}
                    class="bg-white rounded-lg border border-gray-200 hover:border-blue-300 hover:shadow-md transition-all duration-200 overflow-hidden"
                  >
                    <div class="px-5 py-4">
                      <%!-- Header: badge + title --%>
                      <div class="flex items-start gap-3 mb-2">
                        <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium border mt-0.5 #{source_badge_class(result.source)}"}>
                          {source_label(result.source)}
                        </span>
                        <div class="flex-1 min-w-0">
                          <h3 class="font-semibold text-gray-900 leading-tight">
                            {result.title}
                          </h3>
                        </div>
                      </div>

                      <%!-- Snippet --%>
                      <div class="text-sm text-gray-600 mt-2 leading-relaxed pl-[calc(theme(spacing.3)+theme(spacing[2.5])+theme(spacing[2.5]))]">
                        <span>{raw(result.snippet)}</span>
                      </div>

                      <%!-- Action buttons --%>
                      <div class="flex items-center gap-2 mt-3 pl-[calc(theme(spacing.3)+theme(spacing[2.5])+theme(spacing[2.5]))]">
                        <button
                          :if={result.section_number}
                          phx-click="find_related"
                          phx-value-section={result.section_number}
                          class="text-xs px-2.5 py-1 rounded border border-gray-200 text-gray-600 hover:bg-blue-50 hover:border-blue-200 hover:text-blue-700 transition-colors"
                        >
                          Find Related
                        </button>
                        <.link
                          :if={result.section_number}
                          navigate={~p"/section/#{result.section_number}"}
                          class="text-xs px-2.5 py-1 rounded border border-gray-200 text-gray-600 hover:bg-gray-50 hover:border-gray-300 transition-colors"
                        >
                          View Section
                        </.link>
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Related panel --%>
              <aside :if={@related_panel} class="w-80 shrink-0">
                <div class="bg-white rounded-lg border border-gray-200 shadow-sm sticky top-6">
                  <div class="px-4 py-3 bg-gray-50 border-b border-gray-200 flex items-center justify-between">
                    <h3 class="text-sm font-semibold text-gray-700">
                      Related to SEC. {@related_panel.source_section}
                    </h3>
                    <button
                      phx-click="close_related"
                      class="p-1 text-gray-400 hover:text-gray-600 rounded transition-colors"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </div>
                  <div class="p-3 space-y-2 max-h-[calc(100vh-300px)] overflow-y-auto">
                    <div :if={@related_panel.related == []} class="text-sm text-gray-400 text-center py-4">
                      No related sections found
                    </div>
                    <div
                      :for={rel <- @related_panel.related}
                      class="p-2.5 rounded border border-gray-100 hover:border-blue-200 hover:bg-blue-50/30 transition-colors"
                    >
                      <div class="flex items-center gap-2 mb-1">
                        <span class={"inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium #{source_badge_class(rel.source)}"}>
                          {source_label(rel.source)}
                        </span>
                        <span class="text-xs font-medium text-gray-700 truncate">{rel.title}</span>
                      </div>
                      <div class="text-xs text-gray-500 line-clamp-2 leading-relaxed">
                        {raw(rel.snippet)}
                      </div>
                      <.link
                        :if={rel.section_number}
                        navigate={~p"/section/#{rel.section_number}"}
                        class="text-[10px] text-blue-600 hover:text-blue-800 mt-1 inline-block"
                      >
                        View section ->
                      </.link>
                    </div>
                  </div>
                </div>
              </aside>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp filter_placeholder(:contains), do: "Search term..."
  defp filter_placeholder(:not_contains), do: "Exclude term..."
  defp filter_placeholder(:exact_phrase), do: "Exact phrase..."
  defp filter_placeholder(:near), do: "Word to find nearby..."
  defp filter_placeholder(:field), do: "field:value..."
end
