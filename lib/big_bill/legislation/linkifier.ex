defmodule BigBill.Legislation.Linkifier do
  @moduledoc """
  Converts raw bill section text into HTML with clickable cross-reference links.

  Internal section references (SEC. 10105, section 70301) become clickable buttons
  that open the section preview modal. External U.S.C. references get tooltips.
  """

  alias BigBill.Legislation.Parser

  @doc """
  Convert plain section text to HTML with linked cross-references.
  """
  @spec linkify(String.t()) :: String.t()
  def linkify(text) when is_binary(text) do
    valid = section_number_set()

    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> link_internal_sections(valid)
    |> link_usc_references()
  end

  defp link_internal_sections(html, valid) do
    # Match SEC. XXXXX or section XXXXX (5-6 digit numbers)
    Regex.replace(
      ~r/(SEC\.\s*|[Ss]ections?\s+)(\d{5,6})/,
      html,
      fn full, prefix, num ->
        if MapSet.member?(valid, num) do
          ~s(#{prefix}<span data-section="#{num}" class="section-link text-blue-600 underline decoration-dotted cursor-pointer hover:text-blue-800 font-medium">#{num}</span>)
        else
          full
        end
      end
    )
  end

  defp link_usc_references(html) do
    Regex.replace(
      ~r/(\d{1,2})\s+(U\.S\.C\.)\s+([\d]+(?:\([a-zA-Z0-9]+\))*)/,
      html,
      fn _full, title, usc, section ->
        ref = "#{title} #{usc} #{section}"
        ~s(<span class="usc-ref text-purple-600 underline decoration-dotted cursor-help" title="#{ref} — External federal statute reference">#{ref}</span>)
      end
    )
  end

  # Cache the set of valid section numbers (parsed once per node)
  defp section_number_set do
    case :persistent_term.get({__MODULE__, :sections}, nil) do
      nil ->
        bill_path = Path.join(File.cwd!(), "bigbill.txt")

        set =
          if File.exists?(bill_path) do
            Parser.parse(bill_path)
            |> Enum.map(& &1.section_number)
            |> MapSet.new()
          else
            MapSet.new()
          end

        :persistent_term.put({__MODULE__, :sections}, set)
        set

      set ->
        set
    end
  end
end
