defmodule BigBillWeb.DashboardLive do
  use BigBillWeb, :live_view

  alias BigBill.Legislation.Parser

  @impl true
  def mount(_params, _session, socket) do
    bill_path = Path.join(:code.priv_dir(:big_bill), "../bigbill.txt")

    sections =
      if File.exists?(bill_path) do
        Parser.parse(bill_path)
      else
        []
      end

    stats = Parser.stats(sections)
    batches = Parser.batch_for_analysis(sections)
    by_title = Parser.group_by_title(sections)

    titles =
      Parser.title_boundaries()
      |> Enum.map(fn %{num: num, name: name} ->
        title_sections = Map.get(by_title, num, [])
        total_lines = Enum.sum(Enum.map(title_sections, & &1.line_count))
        pct = if stats.total_lines > 0, do: Float.round(total_lines / stats.total_lines * 100, 1), else: 0.0

        %{
          num: num,
          name: name,
          section_count: length(title_sections),
          line_count: total_lines,
          pct: pct
        }
      end)

    socket =
      socket
      |> assign(:page_title, "Big Beautiful Bill — Analysis Dashboard")
      |> assign(:stats, stats)
      |> assign(:titles, titles)
      |> assign(:batch_count, length(batches))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-6xl mx-auto px-4 py-8">
        <h1 class="text-3xl font-bold text-gray-900 mb-2">
          The Big Beautiful Bill
        </h1>
        <p class="text-gray-600 mb-8">
          Public Law 119-21 · 119th Congress · Signed July 4, 2025
        </p>

        <div class="flex gap-3 mb-8">
          <.link navigate={~p"/search"} class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors text-sm font-medium">
            Search
          </.link>
          <.link navigate={~p"/drilldown"} class="px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors text-sm font-medium">
            Advanced Drilldown
          </.link>
        </div>

        <div class="grid grid-cols-4 gap-4 mb-8">
          <div class="bg-white rounded-lg border border-gray-200 p-4">
            <div class="text-2xl font-bold text-gray-900">{@stats.total_sections}</div>
            <div class="text-sm text-gray-500">Sections</div>
          </div>
          <div class="bg-white rounded-lg border border-gray-200 p-4">
            <div class="text-2xl font-bold text-gray-900">{length(@titles)}</div>
            <div class="text-sm text-gray-500">Titles</div>
          </div>
          <div class="bg-white rounded-lg border border-gray-200 p-4">
            <div class="text-2xl font-bold text-gray-900">{format_number(@stats.total_lines)}</div>
            <div class="text-sm text-gray-500">Lines of Text</div>
          </div>
          <div class="bg-white rounded-lg border border-gray-200 p-4">
            <div class="text-2xl font-bold text-gray-900">{@batch_count}</div>
            <div class="text-sm text-gray-500">Analysis Batches</div>
          </div>
        </div>

        <h2 class="text-xl font-semibold text-gray-900 mb-4">Titles</h2>
        <div class="space-y-3">
          <.link
            :for={title <- @titles}
            navigate={~p"/title/#{title.num}"}
            class="block bg-white rounded-lg border border-gray-200 p-4 hover:border-blue-400 hover:shadow-sm transition-all"
          >
            <div class="flex items-center justify-between">
              <div>
                <span class="font-mono text-sm text-gray-400 mr-2">Title {to_roman(title.num)}</span>
                <span class="font-medium text-gray-900">{title.name}</span>
              </div>
              <div class="flex items-center gap-4 text-sm text-gray-500">
                <span>{title.section_count} sections</span>
                <span>{format_number(title.line_count)} lines</span>
                <span class="font-mono">{title.pct}%</span>
              </div>
            </div>
            <div class="mt-2 h-1.5 bg-gray-100 rounded-full overflow-hidden">
              <div
                class="h-full bg-blue-500 rounded-full"
                style={"width: #{title.pct}%"}
              >
              </div>
            </div>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

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
end
