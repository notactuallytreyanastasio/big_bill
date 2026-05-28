defmodule BigBillWeb.TitleLive do
  use BigBillWeb, :live_view

  alias BigBill.Legislation.Parser

  @impl true
  def mount(%{"title_num" => title_num_str}, _session, socket) do
    title_num = String.to_integer(title_num_str)
    bill_path = Path.join(:code.priv_dir(:big_bill), "../bigbill.txt")

    sections =
      if File.exists?(bill_path) do
        Parser.parse(bill_path)
        |> Enum.filter(&(&1.title_num == title_num))
      else
        []
      end

    title_info =
      Enum.find(Parser.title_boundaries(), fn %{num: num} -> num == title_num end)

    by_subtitle =
      sections
      |> Enum.group_by(fn sec -> sec.subtitle || "General" end)
      |> Enum.sort_by(fn {_subtitle, secs} ->
        secs |> Enum.map(& &1.start_line) |> Enum.min(fn -> 0 end)
      end)

    socket =
      socket
      |> assign(:page_title, "Title #{to_roman(title_num)} — #{title_info.name}")
      |> assign(:title_num, title_num)
      |> assign(:title_info, title_info)
      |> assign(:sections, sections)
      |> assign(:by_subtitle, by_subtitle)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-6xl mx-auto px-4 py-8">
        <.link navigate={~p"/"} class="text-sm text-blue-600 hover:text-blue-800 mb-4 inline-block">
          &larr; Back to Dashboard
        </.link>

        <h1 class="text-2xl font-bold text-gray-900 mb-1">
          Title {to_roman(@title_num)} — {@title_info.name}
        </h1>
        <p class="text-gray-500 mb-6">
          {length(@sections)} sections · Lines {@title_info.start_line}-{@title_info.end_line}
        </p>

        <div :for={{subtitle, secs} <- @by_subtitle} class="mb-8">
          <h2 class="text-lg font-semibold text-gray-800 mb-3 border-b border-gray-200 pb-2">
            {subtitle}
          </h2>
          <div class="space-y-2">
            <.link
              :for={sec <- secs}
              navigate={~p"/section/#{sec.section_number}"}
              class="block bg-white rounded border border-gray-200 px-4 py-3 hover:border-blue-400 hover:shadow-sm transition-all"
            >
              <div class="flex items-center justify-between">
                <div>
                  <span class="font-mono text-sm text-blue-600 mr-2">SEC. {sec.section_number}</span>
                  <span class="text-gray-900">{sec.title}</span>
                </div>
                <span class="text-xs text-gray-400">{sec.line_count} lines</span>
              </div>
              <div :if={sec.chapter} class="text-xs text-gray-400 mt-1">
                {sec.chapter}
                <span :if={sec.subchapter}> &rsaquo; {sec.subchapter}</span>
              </div>
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
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
end
