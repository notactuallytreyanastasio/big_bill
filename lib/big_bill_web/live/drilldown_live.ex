defmodule BigBillWeb.DrilldownLive do
  use BigBillWeb, :live_view

  alias BigBill.Search
  alias BigBill.Search.Advanced
  alias BigBill.Legislation.Parser
  alias BigBill.Legislation.Linkifier

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
      |> assign(:view_mode, :entities)
      |> assign(:filters, [default_filter()])
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
      |> assign(:entities, [])
      |> assign(:money_flows, [])
      |> assign(:entity_filter, "all")
      |> assign(:show_network_modal, false)
      |> assign(:show_section_modal, false)
      |> assign(:section_preview, nil)

    # Auto-load entities on mount since it's the default view
    send(self(), :load_initial_data)

    {:ok, socket}
  end

  # -------------------------------------------------------------------
  # Events
  # -------------------------------------------------------------------

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) do
    mode = String.to_existing_atom(mode)
    socket = assign(socket, :view_mode, mode)

    socket =
      case mode do
        :entities -> load_entities(socket)
        :money -> load_money(socket)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("filter_entities", %{"outcome" => outcome}, socket) do
    {:noreply, assign(socket, :entity_filter, outcome)}
  end

  def handle_event("preview_section", %{"sec" => sec_num}, socket) do
    result = Search.get_full_content(%{source: :bill, section_number: sec_num})

    socket =
      socket
      |> assign(:section_preview, result)
      |> assign(:show_section_modal, true)

    {:noreply, socket}
  end

  def handle_event("close_section_preview", _params, socket) do
    {:noreply, assign(socket, :show_section_modal, false)}
  end

  def handle_event("open_network", _params, socket) do
    socket = assign(socket, :show_network_modal, true)
    # Re-push network data so hook renders when modal opens
    socket = push_event(socket, "network_data", %{entities: socket.assigns.entities})
    {:noreply, socket}
  end

  def handle_event("close_network", _params, socket) do
    {:noreply, assign(socket, :show_network_modal, false)}
  end

  # Form-based filter updates (fixes the bare-input phx-change issue)
  def handle_event("form_change", params, socket) do
    filters =
      Enum.map(socket.assigns.filters, fn f ->
        value = Map.get(params, "value_#{f.id}", f.value)
        type_str = Map.get(params, "type_#{f.id}")
        type = if type_str, do: String.to_existing_atom(type_str), else: f.type

        near_n =
          case Map.get(params, "near_#{f.id}") do
            nil -> f.near_n
            n_str ->
              case Integer.parse(n_str) do
                {val, _} -> max(1, val)
                :error -> f.near_n
              end
          end

        %{f | value: value, type: type, near_n: near_n}
      end)

    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("add_filter", _params, socket) do
    filters = socket.assigns.filters ++ [default_filter()]
    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("remove_filter", %{"id" => id}, socket) do
    filters = Enum.reject(socket.assigns.filters, &(&1.id == id))
    filters = if filters == [], do: [default_filter()], else: filters
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

    {:noreply, maybe_reload_data(socket)}
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

    {:noreply, maybe_reload_data(socket)}
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
  def handle_info(:load_initial_data, socket) do
    {:noreply, load_entities(socket)}
  end

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
  # Data loaders
  # -------------------------------------------------------------------

  defp load_entities(socket) do
    scope = duckdb_scope(socket.assigns)
    entities = Advanced.entities_in_scope(scope)

    entities =
      case entities do
        {:error, _} -> []
        list when is_list(list) -> list
        _ -> []
      end

    socket
    |> assign(:entities, entities)
    |> push_event("entity_data", %{entities: entities})
    |> push_event("network_data", %{entities: entities})
  end

  defp load_money(socket) do
    scope = duckdb_scope(socket.assigns)
    flows = Advanced.money_in_scope(scope)

    flows =
      case flows do
        {:error, _} -> []
        list when is_list(list) -> list
        _ -> []
      end

    socket
    |> assign(:money_flows, flows)
    |> push_event("money_data", %{flows: flows})
  end

  defp maybe_reload_data(socket) do
    case socket.assigns.view_mode do
      :entities -> load_entities(socket)
      :money -> load_money(socket)
      _ -> socket
    end
  end

  defp duckdb_scope(assigns) do
    titles = assigns.scope_titles

    case MapSet.size(titles) do
      0 -> :all
      1 -> {:title, Enum.at(MapSet.to_list(titles), 0)}
      _ -> :all
    end
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

  defp filtered_entities(entities, "all"), do: entities
  defp filtered_entities(entities, outcome), do: Enum.filter(entities, &(&1.outcome == outcome))

  defp entity_summary(entities) do
    benefits = Enum.count(entities, &(&1.outcome == "benefits"))
    loses = Enum.count(entities, &(&1.outcome == "loses"))
    unique = entities |> Enum.map(& &1.entity_name) |> Enum.uniq() |> length()
    {benefits, loses, unique}
  end

  defp format_dollars(nil), do: nil
  defp format_dollars(0), do: nil
  defp format_dollars(+0.0), do: nil
  defp format_dollars(n) when is_float(n) or is_integer(n) do
    cond do
      n >= 1.0e12 -> "$#{:erlang.float_to_binary(n / 1.0e12, decimals: 2)}T"
      n >= 1.0e9 -> "$#{:erlang.float_to_binary(n / 1.0e9, decimals: 2)}B"
      n >= 1.0e6 -> "$#{:erlang.float_to_binary(n / 1.0e6, decimals: 1)}M"
      n >= 1.0e3 -> "$#{:erlang.float_to_binary(n / 1.0e3, decimals: 0)}K"
      true -> "$#{round(n)}"
    end
  end
  defp format_dollars(_), do: nil

  defp money_summary(flows) do
    total = flows |> Enum.map(& &1.amount_dollars) |> Enum.reject(&is_nil/1) |> Enum.sum()
    count = length(flows)
    {count, total}
  end

  defp direction_badge_class("appropriation"), do: "bg-blue-100 text-blue-700"
  defp direction_badge_class("spending"), do: "bg-blue-100 text-blue-700"
  defp direction_badge_class("rescission"), do: "bg-red-100 text-red-700"
  defp direction_badge_class("cut"), do: "bg-red-100 text-red-700"
  defp direction_badge_class("revenue"), do: "bg-green-100 text-green-700"
  defp direction_badge_class("tax"), do: "bg-green-100 text-green-700"
  defp direction_badge_class(_), do: "bg-gray-100 text-gray-700"

  # -------------------------------------------------------------------
  # Render
  # -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-[1920px] mx-auto px-6 py-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-6">
          <div>
            <.link navigate={~p"/"} class="text-sm text-blue-600 hover:text-blue-800 mb-1 inline-block">
              &larr; Back to Dashboard
            </.link>
            <h1 class="text-2xl font-bold text-gray-900">Drilldown</h1>
            <p class="text-sm text-gray-500 mt-1">Search the bill, explore who wins and loses, follow the money</p>
          </div>
          <.link navigate={~p"/search"} class="text-sm px-3 py-1.5 rounded border border-gray-300 hover:bg-gray-50 transition-colors">
            Simple Search
          </.link>
        </div>

        <%!-- Tabs --%>
        <div class="flex gap-1 mb-5 border-b border-gray-200">
          <button
            :for={{mode, label, icon} <- [
              {:entities, "Winners & Losers", "hero-user-group"},
              {:money, "Money Flows", "hero-banknotes"},
              {:search, "Text Search", "hero-magnifying-glass"}
            ]}
            phx-click="switch_view"
            phx-value-mode={mode}
            class={[
              "px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors flex items-center gap-2",
              if(@view_mode == mode,
                do: "border-blue-600 text-blue-600",
                else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
              )
            ]}
          >
            <.icon name={icon} class="w-4 h-4" />
            {label}
          </button>
        </div>

        <%!-- ============ ENTITIES VIEW (full width) ============ --%>
            <div :if={@view_mode == :entities}>
              <% {ben_count, lose_count, unique_count} = entity_summary(@entities) %>

              <%!-- Stats + Network button --%>
              <div class="grid grid-cols-4 gap-4 mb-5">
                <div class="bg-white rounded-lg border border-gray-200 p-4">
                  <div class="text-2xl font-bold text-green-600">{ben_count}</div>
                  <div class="text-xs text-gray-500 mt-1">Benefit mentions</div>
                </div>
                <div class="bg-white rounded-lg border border-gray-200 p-4">
                  <div class="text-2xl font-bold text-red-600">{lose_count}</div>
                  <div class="text-xs text-gray-500 mt-1">Lose mentions</div>
                </div>
                <div class="bg-white rounded-lg border border-gray-200 p-4">
                  <div class="text-2xl font-bold text-gray-800">{unique_count}</div>
                  <div class="text-xs text-gray-500 mt-1">Unique entities</div>
                </div>
                <button
                  phx-click="open_network"
                  class="bg-white rounded-lg border border-gray-200 p-4 hover:border-purple-300 hover:shadow-md transition-all text-left group"
                >
                  <div class="flex items-center gap-2">
                    <.icon name="hero-share" class="w-5 h-5 text-purple-500" />
                    <span class="text-sm font-semibold text-gray-700 group-hover:text-purple-700">Network Graph</span>
                  </div>
                  <div class="text-xs text-gray-400 mt-1">View entity-section connections</div>
                </button>
              </div>

              <%!-- Full-width D3 Chart --%>
              <div class="bg-white rounded-lg border border-gray-200 shadow-sm p-5 mb-5">
                <h3 class="text-lg font-bold text-gray-900 mb-4">Who Benefits vs Who Loses</h3>
                <div id="entity-chart" phx-hook="EntityChart" phx-update="ignore" class="w-full overflow-x-auto"></div>
              </div>

              <%!-- Full-width Filter + Table --%>
              <div class="bg-white rounded-lg border border-gray-200 shadow-sm overflow-hidden">
                <div class="px-5 py-4 bg-gray-50 border-b border-gray-200 flex items-center gap-3">
                  <h3 class="text-lg font-bold text-gray-900">Entity Details</h3>
                  <div class="flex gap-1 ml-auto">
                    <button
                      :for={{val, label, color} <- [
                        {"all", "All", "gray"},
                        {"benefits", "Benefits", "green"},
                        {"loses", "Loses", "red"}
                      ]}
                      phx-click="filter_entities"
                      phx-value-outcome={val}
                      class={[
                        "px-3 py-1 rounded-full text-xs font-medium transition-colors",
                        if(@entity_filter == val,
                          do: "bg-#{color}-100 text-#{color}-700 ring-1 ring-#{color}-300",
                          else: "text-gray-500 hover:bg-gray-100"
                        )
                      ]}
                    >
                      {label}
                    </button>
                  </div>
                </div>
                <div class="max-h-[600px] overflow-y-auto">
                  <table class="w-full text-sm">
                    <thead class="sticky top-0 bg-gray-50 border-b border-gray-200">
                      <tr>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Entity</th>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Type</th>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Outcome</th>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Section</th>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Detail</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={entity <- filtered_entities(@entities, @entity_filter)}
                        class="border-b border-gray-100 hover:bg-gray-50 transition-colors"
                      >
                        <td class="px-4 py-2.5 font-medium text-gray-900">{entity.entity_name}</td>
                        <td class="px-4 py-2.5">
                          <span class="inline-flex px-2 py-0.5 rounded-full text-xs bg-gray-100 text-gray-600">
                            {entity.entity_type}
                          </span>
                        </td>
                        <td class="px-4 py-2.5">
                          <span class={[
                            "inline-flex px-2 py-0.5 rounded-full text-xs font-medium",
                            if(entity.outcome == "benefits", do: "bg-green-100 text-green-700", else: "bg-red-100 text-red-700")
                          ]}>
                            {entity.outcome}
                          </span>
                        </td>
                        <td class="px-4 py-2.5">
                          <button
                            :if={entity.section_number}
                            phx-click="preview_section"
                            phx-value-sec={entity.section_number}
                            class="group relative text-blue-600 hover:text-blue-800 text-xs font-medium underline decoration-dotted cursor-pointer"
                          >
                            &sect;{entity.section_number}
                            <span class="pointer-events-none absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block w-72 p-3 rounded-lg bg-gray-900 text-white text-xs leading-relaxed shadow-xl z-50">
                              <span class="font-semibold text-blue-300">Section {entity.section_number}</span>
                              <span class="block mt-1 text-gray-300 line-clamp-4">{entity.detail}</span>
                              <span class="block mt-1 text-blue-400">Click to preview section &rarr;</span>
                            </span>
                          </button>
                        </td>
                        <td class="px-4 py-2.5 text-gray-600 text-xs max-w-md">
                          <span class="line-clamp-2">{entity.detail}</span>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                  <div :if={filtered_entities(@entities, @entity_filter) == []} class="py-12 text-center text-gray-400">
                    No entities found. Select a title scope or load all data.
                  </div>
                </div>
              </div>

              <%!-- Network Graph Modal --%>
              <div
                :if={@show_network_modal}
                data-modal
                class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
              >
                <div
                  class="bg-white rounded-xl shadow-2xl w-[95vw] h-[90vh] flex flex-col overflow-hidden"
                  phx-click-away="close_network"
                >
                  <div class="flex items-center justify-between px-6 py-4 border-b border-gray-200 bg-gray-50">
                    <div>
                      <h2 class="text-lg font-bold text-gray-900">Entity-Section Network</h2>
                      <p class="text-xs text-gray-500">Drag to rearrange. Green = benefits, Red = loses. Scroll to zoom.</p>
                    </div>
                    <button phx-click="close_network" class="p-2 hover:bg-gray-200 rounded-lg transition-colors">
                      <.icon name="hero-x-mark" class="w-5 h-5 text-gray-500" />
                    </button>
                  </div>
                  <div class="flex-1 p-2">
                    <div id="entity-network" phx-hook="EntityNetwork" phx-update="ignore" class="w-full h-full"></div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- ============ MONEY VIEW ============ --%>
            <div :if={@view_mode == :money}>
              <% {flow_count, total_dollars} = money_summary(@money_flows) %>

              <%!-- Stats bar --%>
              <div class="grid grid-cols-2 gap-4 mb-5">
                <div class="bg-white rounded-lg border border-gray-200 p-5">
                  <div class="text-3xl font-bold text-gray-800">{flow_count}</div>
                  <div class="text-sm text-gray-500 mt-1">Money flow provisions</div>
                </div>
                <div class="bg-white rounded-lg border border-gray-200 p-5">
                  <div class="text-3xl font-bold text-blue-600">{format_dollars(total_dollars) || "$0"}</div>
                  <div class="text-sm text-gray-500 mt-1">Total quantified</div>
                </div>
              </div>

              <%!-- Full-width D3 Chart --%>
              <div class="bg-white rounded-lg border border-gray-200 shadow-sm p-5 mb-5">
                <h3 class="text-lg font-bold text-gray-900 mb-4">Money Flows by Amount</h3>
                <div id="money-chart" phx-hook="MoneyChart" phx-update="ignore" class="w-full overflow-x-auto"></div>
              </div>

              <%!-- Full-width Table --%>
              <div class="bg-white rounded-lg border border-gray-200 shadow-sm overflow-hidden">
                <div class="px-5 py-4 bg-gray-50 border-b border-gray-200">
                  <h3 class="text-lg font-bold text-gray-900">All Money Flows</h3>
                </div>
                <div class="max-h-[600px] overflow-y-auto">
                  <table class="w-full text-sm">
                    <thead class="sticky top-0 bg-gray-50 border-b border-gray-200">
                      <tr>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Section</th>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Title</th>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Amount</th>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Direction</th>
                        <th class="text-left px-4 py-2 text-xs font-semibold text-gray-500 uppercase">Notes</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={flow <- @money_flows}
                        class="border-b border-gray-100 hover:bg-gray-50 transition-colors"
                      >
                        <td class="px-4 py-2.5">
                          <button
                            :if={flow.section_number}
                            phx-click="preview_section"
                            phx-value-sec={flow.section_number}
                            class="group relative text-blue-600 hover:text-blue-800 font-medium underline decoration-dotted cursor-pointer"
                          >
                            &sect;{flow.section_number}
                            <span class="pointer-events-none absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block w-72 p-3 rounded-lg bg-gray-900 text-white text-xs leading-relaxed shadow-xl z-50">
                              <span class="font-semibold text-blue-300">Section {flow.section_number}</span>
                              <span class="block mt-1 text-gray-400">{flow.title_name}</span>
                              <span :if={flow.notes} class="block mt-1 text-gray-300 line-clamp-3">{flow.notes}</span>
                              <span class="block mt-1 text-blue-400">Click to preview section &rarr;</span>
                            </span>
                          </button>
                        </td>
                        <td class="px-4 py-2.5 text-gray-600 text-xs">{flow.title_name}</td>
                        <td class="px-4 py-2.5 font-mono font-semibold text-gray-900">
                          {format_dollars(flow.amount_dollars) || flow.amount_text}
                        </td>
                        <td class="px-4 py-2.5">
                          <span :if={flow.direction} class={"inline-flex px-2 py-0.5 rounded-full text-xs font-medium #{direction_badge_class(flow.direction)}"}>
                            {flow.direction}
                          </span>
                        </td>
                        <td class="px-4 py-2.5 text-gray-600 text-xs max-w-sm truncate" title={flow.notes}>
                          {flow.notes}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                  <div :if={@money_flows == []} class="py-12 text-center text-gray-400">
                    No money flows found. Select a title scope or load all data.
                  </div>
                </div>
              </div>
            </div>

        <%!-- ============ SEARCH VIEW (with sidebar) ============ --%>
        <div :if={@view_mode == :search} class="flex gap-6">
          <%!-- Sidebar --%>
          <aside class={["shrink-0 transition-all duration-300 overflow-hidden", if(@sidebar_open, do: "w-64", else: "w-0")]}>
            <div class="w-64 bg-white rounded-lg border border-gray-200 shadow-sm overflow-hidden">
              <div class="px-4 py-3 bg-gray-50 border-b border-gray-200">
                <h2 class="text-sm font-semibold text-gray-700 uppercase tracking-wider">Scope</h2>
              </div>
              <div class="p-3 max-h-[calc(100vh-320px)] overflow-y-auto space-y-4">
                <div>
                  <label class="flex items-center gap-2 cursor-pointer group mb-2">
                    <input type="checkbox" checked={@scope_all_titles} phx-click="toggle_all_titles" class="rounded border-gray-300 text-blue-600 focus:ring-blue-500 h-4 w-4" />
                    <span class="text-sm font-semibold text-gray-700">All Titles</span>
                  </label>
                  <div class="ml-6 space-y-1">
                    <label :for={tb <- @title_boundaries} class="flex items-center gap-2 cursor-pointer group">
                      <input type="checkbox" checked={MapSet.member?(@scope_titles, tb.num)} phx-click="toggle_title" phx-value-num={tb.num} class="rounded border-gray-300 text-blue-600 h-3.5 w-3.5" />
                      <span class="text-xs text-gray-600 leading-tight">Title {to_roman(tb.num)} -- {tb.name}</span>
                    </label>
                  </div>
                </div>
                <div class="border-t border-gray-100 pt-3">
                  <label class="flex items-center gap-2 cursor-pointer group mb-2">
                    <input type="checkbox" checked={@scope_all_analysis} phx-click="toggle_all_analysis" class="rounded border-gray-300 text-emerald-600 h-4 w-4" />
                    <span class="text-sm font-semibold text-gray-700">All Analysis</span>
                  </label>
                  <div class="ml-6 space-y-1">
                    <label :for={file <- @analysis_files} class="flex items-center gap-2 cursor-pointer group">
                      <input type="checkbox" checked={MapSet.member?(@scope_analysis_files, file)} phx-click="toggle_analysis_file" phx-value-file={file} class="rounded border-gray-300 text-emerald-600 h-3.5 w-3.5" />
                      <span class="text-xs text-gray-600 truncate">{analysis_display_name(file)}</span>
                    </label>
                  </div>
                </div>
                <div class="border-t border-gray-100 pt-3">
                  <label class="flex items-center gap-2 cursor-pointer group mb-2">
                    <input type="checkbox" checked={@scope_all_graph} phx-click="toggle_all_graph" class="rounded border-gray-300 text-purple-600 h-4 w-4" />
                    <span class="text-sm font-semibold text-gray-700">Graph Nodes</span>
                  </label>
                  <div class="ml-6 space-y-1">
                    <label :for={type <- ~w(action observation goal decision option outcome)} class="flex items-center gap-2 cursor-pointer group">
                      <input type="checkbox" checked={MapSet.member?(@scope_graph_types, type)} phx-click="toggle_graph_type" phx-value-type={type} class="rounded border-gray-300 text-purple-600 h-3.5 w-3.5" />
                      <span class="text-xs text-gray-600 capitalize">{type}s only</span>
                    </label>
                  </div>
                </div>
              </div>
            </div>
          </aside>

          <div class="flex-1 min-w-0">
            <button phx-click="toggle_sidebar" class="mb-3 text-xs text-gray-500 hover:text-gray-700 flex items-center gap-1">
              <.icon name={if @sidebar_open, do: "hero-chevron-double-left", else: "hero-chevron-double-right"} class="w-4 h-4" />
              {if @sidebar_open, do: "Hide scope", else: "Show scope"}
            </button>

            <form phx-change="form_change" phx-submit="search" class="bg-white rounded-lg border border-gray-200 shadow-sm p-4 mb-4">
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
                        type="button"
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
                      <select
                        name={"type_#{filter.id}"}
                        class="text-sm border-gray-300 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 bg-white py-1.5 pr-8"
                      >
                        <option :for={{val, label} <- @filter_types} value={val} selected={filter.type == val}>
                          {label}
                        </option>
                      </select>

                      <input
                        type="text"
                        value={filter.value}
                        name={"value_#{filter.id}"}
                        placeholder={filter_placeholder(filter.type)}
                        phx-debounce="200"
                        class="flex-1 text-sm border-gray-300 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 py-1.5"
                      />

                      <div :if={filter.type == :near} class="flex items-center gap-1">
                        <span class="text-xs text-gray-500 whitespace-nowrap">within</span>
                        <input
                          type="number"
                          value={filter.near_n}
                          name={"near_#{filter.id}"}
                          min="1"
                          max="50"
                          class="w-14 text-sm border-gray-300 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 py-1.5 text-center"
                        />
                        <span class="text-xs text-gray-500 whitespace-nowrap">words</span>
                      </div>

                      <button
                        type="button"
                        phx-click="remove_filter"
                        phx-value-id={filter.id}
                        class="p-1 text-gray-400 hover:text-red-500 hover:bg-red-50 rounded transition-colors"
                        title="Remove filter"
                      >
                        <.icon name="hero-x-mark" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                </div>

                <div class="flex items-center justify-between mt-3 pt-3 border-t border-gray-100">
                  <button
                    type="button"
                    phx-click="add_filter"
                    class="text-sm text-blue-600 hover:text-blue-800 font-medium flex items-center gap-1 transition-colors"
                  >
                    <.icon name="hero-plus" class="w-4 h-4" />
                    Add Filter
                  </button>

                  <button
                    type="submit"
                    disabled={@searching}
                    class={[
                      "px-5 py-2 rounded-lg text-sm font-semibold transition-all",
                      "bg-blue-600 text-white hover:bg-blue-700 shadow-sm hover:shadow"
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
              </form>

              <%!-- Results --%>
              <div class="flex gap-4">
                <div class={[
                  "min-w-0 transition-all duration-300",
                  if(@related_panel, do: "flex-1", else: "w-full")
                ]}>
                  <div :if={@result_count > 0} class="text-sm text-gray-500 mb-3">
                    {if @result_count == 100, do: "Showing top 100", else: "#{@result_count}"} results
                  </div>

                  <div :if={@results == [] and !@searching} class="py-16 text-center bg-white rounded-lg border border-gray-200">
                    <.icon name="hero-magnifying-glass" class="w-12 h-12 mx-auto text-gray-300 mb-3" />
                    <div class="text-gray-400 text-lg mb-1">Ready to search</div>
                    <div class="text-gray-400 text-sm">Add filters above and click Search</div>
                  </div>

                  <div class="space-y-3">
                    <div
                      :for={result <- @results}
                      class="bg-white rounded-lg border border-gray-200 hover:border-blue-300 hover:shadow-md transition-all duration-200 overflow-hidden cursor-pointer"
                      phx-click={result.section_number && "preview_section"}
                      phx-value-sec={result.section_number}
                    >
                      <div class="px-5 py-4">
                        <div class="flex items-start gap-3 mb-2">
                          <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium border mt-0.5 #{source_badge_class(result.source)}"}>
                            {source_label(result.source)}
                          </span>
                          <div class="flex-1 min-w-0">
                            <h3 class="font-semibold text-gray-900 leading-tight">{result.title}</h3>
                          </div>
                          <.icon :if={result.section_number} name="hero-arrow-top-right-on-square" class="w-4 h-4 text-gray-400 shrink-0 mt-0.5" />
                        </div>
                        <div class="text-sm text-gray-600 mt-2 leading-relaxed ml-[70px]">
                          <span>{raw(result.snippet)}</span>
                        </div>
                        <div class="flex items-center gap-2 mt-3 ml-[70px]">
                          <button
                            :if={result.section_number}
                            phx-click="find_related"
                            phx-value-section={result.section_number}
                            class="text-xs px-2.5 py-1 rounded border border-gray-200 text-gray-600 hover:bg-blue-50 hover:border-blue-200 hover:text-blue-700 transition-colors"
                          >
                            Find Related
                          </button>
                          <button
                            :if={result.section_number}
                            phx-click="preview_section"
                            phx-value-sec={result.section_number}
                            class="text-xs px-2.5 py-1 rounded border border-gray-200 text-gray-600 hover:bg-gray-50 hover:border-gray-300 transition-colors"
                          >
                            View Section
                          </button>
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
                        <.icon name="hero-x-mark" class="w-4 h-4" />
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

      <%!-- Section Preview Modal (z-[60] so it stacks above the network modal at z-50) --%>
      <div
        :if={@show_section_modal && @section_preview}
        class="fixed inset-0 z-[60] flex items-center justify-center"
      >
        <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_section_preview"></div>
        <div
          class="relative bg-white rounded-xl shadow-2xl w-[85vw] max-w-5xl h-[85vh] flex flex-col overflow-hidden"
        >
          <div class="flex items-center justify-between px-6 py-4 border-b border-gray-200 bg-gray-50 shrink-0">
            <div>
              <h2 class="text-lg font-bold text-gray-900">{@section_preview.title}</h2>
              <div class="flex items-center gap-3 mt-1 text-xs text-gray-500">
                <span :if={@section_preview.meta[:title_name]}>Title: {@section_preview.meta[:title_name]}</span>
                <span :if={@section_preview.meta[:subtitle]}>Subtitle: {@section_preview.meta[:subtitle]}</span>
                <span :if={@section_preview.meta[:lines]}>Lines: {@section_preview.meta[:lines]}</span>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <.link
                navigate={~p"/section/#{@section_preview.section_number}"}
                class="text-xs px-3 py-1.5 rounded-lg bg-blue-600 text-white hover:bg-blue-700"
              >
                Full Page View
              </.link>
              <button phx-click="close_section_preview" class="p-2 hover:bg-gray-200 rounded-lg transition-colors">
                <.icon name="hero-x-mark" class="w-5 h-5 text-gray-500" />
              </button>
            </div>
          </div>
          <div class="flex-1 overflow-y-auto px-8 py-6" id={"section-text-#{@section_preview.section_number}"} phx-hook="SectionText">
            <pre class="whitespace-pre-wrap text-sm text-gray-800 font-mono leading-relaxed"><%= raw(Linkifier.linkify(@section_preview.content)) %></pre>
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
