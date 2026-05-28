defmodule BigBillWeb.SectionLive do
  use BigBillWeb, :live_view

  alias BigBill.Legislation.Parser

  @impl true
  def mount(%{"section_number" => section_number}, _session, socket) do
    bill_path = Path.join(:code.priv_dir(:big_bill), "../bigbill.txt")

    section =
      if File.exists?(bill_path) do
        Parser.parse(bill_path)
        |> Enum.find(&(&1.section_number == section_number))
      else
        nil
      end

    socket =
      socket
      |> assign(:section, section)
      |> assign(:page_title, section_page_title(section))
      |> assign(:show_raw, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle-raw", _params, socket) do
    {:noreply, assign(socket, :show_raw, !socket.assigns.show_raw)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-6xl mx-auto px-4 py-8">
        <%= if @section do %>
          <.link
            navigate={~p"/title/#{@section.title_num}"}
            class="text-sm text-blue-600 hover:text-blue-800 mb-4 inline-block"
          >
            &larr; Back to Title {to_roman(@section.title_num)}
          </.link>

          <h1 class="text-2xl font-bold text-gray-900 mb-1">
            SEC. {@section.section_number}
          </h1>
          <h2 class="text-lg text-gray-700 mb-4">{@section.title}</h2>

          <div class="flex flex-wrap gap-2 mb-6 text-xs">
            <span class="bg-gray-100 text-gray-600 px-2 py-1 rounded">
              Title {to_roman(@section.title_num)} — {@section.title_name}
            </span>
            <span :if={@section.subtitle} class="bg-blue-50 text-blue-700 px-2 py-1 rounded">
              {@section.subtitle}
            </span>
            <span :if={@section.chapter} class="bg-purple-50 text-purple-700 px-2 py-1 rounded">
              {@section.chapter}
            </span>
            <span class="bg-gray-100 text-gray-600 px-2 py-1 rounded">
              Lines {@section.start_line}-{@section.end_line} ({@section.line_count} lines)
            </span>
          </div>

          <div class="mb-4">
            <button
              phx-click="toggle-raw"
              class="text-sm text-blue-600 hover:text-blue-800 underline"
            >
              <%= if @show_raw, do: "Hide", else: "Show" %> Legislative Text
            </button>
          </div>

          <div :if={@show_raw} class="bg-gray-50 border border-gray-200 rounded-lg p-4 mb-6 overflow-x-auto">
            <pre class="text-xs font-mono text-gray-800 whitespace-pre-wrap">{@section.text}</pre>
          </div>
        <% else %>
          <p class="text-gray-500">Section not found.</p>
          <.link navigate={~p"/"} class="text-blue-600 hover:text-blue-800">
            Back to Dashboard
          </.link>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp section_page_title(nil), do: "Section Not Found"
  defp section_page_title(section), do: "SEC. #{section.section_number} — #{section.title}"

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
