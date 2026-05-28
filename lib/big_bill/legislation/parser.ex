defmodule BigBill.Legislation.Parser do
  @moduledoc """
  Parses the Big Beautiful Bill plaintext into structured sections.

  Reads the bill text file line by line, identifies section boundaries
  (SEC. markers), and tags each section with its structural position
  in the bill hierarchy (Title, Subtitle, Chapter, Subchapter).
  """

  alias BigBill.Legislation.Section

  @type title_info :: %{
          num: pos_integer(),
          name: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer()
        }

  @title_boundaries [
    %{num: 1, name: "Agriculture, Nutrition, and Forestry", start_line: 515, end_line: 2319},
    %{num: 2, name: "Armed Services", start_line: 2320, end_line: 3120},
    %{num: 3, name: "Banking, Housing, and Urban Affairs", start_line: 3121, end_line: 3172},
    %{num: 4, name: "Commerce, Science, and Transportation", start_line: 3173, end_line: 3746},
    %{num: 5, name: "Energy and Natural Resources", start_line: 3747, end_line: 4748},
    %{num: 6, name: "Environment and Public Works", start_line: 4749, end_line: 4930},
    %{num: 7, name: "Finance", start_line: 4931, end_line: 15039},
    %{num: 8, name: "Health, Education, Labor, and Pensions", start_line: 15040, end_line: 16435},
    %{num: 9, name: "Homeland Security and Governmental Affairs", start_line: 16436, end_line: 16787},
    %{num: 10, name: "Judiciary", start_line: 16788, end_line: 18920}
  ]

  @doc """
  Parse the bill text file into a list of sections.
  """
  @spec parse(String.t()) :: [Section.t()]
  def parse(file_path) do
    lines = File.read!(file_path) |> String.split("\n")

    lines
    |> find_section_starts()
    |> build_sections(lines)
  end

  @doc """
  Return the title boundary definitions.
  """
  @spec title_boundaries() :: [title_info()]
  def title_boundaries, do: @title_boundaries

  @doc """
  Group sections by their title number.
  """
  @spec group_by_title([Section.t()]) :: %{pos_integer() => [Section.t()]}
  def group_by_title(sections) do
    Enum.group_by(sections, & &1.title_num)
  end

  @doc """
  Group sections into analysis batches. Large titles get split by
  chapter/subchapter. Small titles stay as single batches.

  Returns a list of {batch_label, [Section.t()]} tuples.
  """
  @spec batch_for_analysis([Section.t()]) :: [{String.t(), [Section.t()]}]
  def batch_for_analysis(sections) do
    sections
    |> group_by_title()
    |> Enum.flat_map(fn {title_num, title_sections} ->
      if length(title_sections) > 15 do
        split_large_title(title_num, title_sections)
      else
        title_info = Enum.find(@title_boundaries, &(&1.num == title_num))
        label = "Title #{to_roman(title_num)} - #{title_info.name}"
        [{label, title_sections}]
      end
    end)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  @doc """
  Return summary statistics about the parsed bill.
  """
  @spec stats([Section.t()]) :: map()
  def stats(sections) do
    by_title = group_by_title(sections)

    title_stats =
      Enum.map(@title_boundaries, fn %{num: num, name: name} ->
        title_sections = Map.get(by_title, num, [])
        total_lines = Enum.sum(Enum.map(title_sections, & &1.line_count))

        %{
          title_num: num,
          title_name: name,
          section_count: length(title_sections),
          total_lines: total_lines
        }
      end)

    %{
      total_sections: length(sections),
      total_lines: Enum.sum(Enum.map(sections, & &1.line_count)),
      titles: title_stats,
      batches: length(batch_for_analysis(sections))
    }
  end

  # --- Private ---

  defp find_section_starts(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} ->
      String.match?(line, ~r/^\s*SEC\.\s+\d/)
    end)
    |> Enum.map(fn {line, idx} ->
      section_number = extract_section_number(line)
      section_title = extract_section_title(line)
      {idx, section_number, section_title}
    end)
  end

  defp build_sections(section_starts, lines) do
    total_lines = length(lines)

    section_starts
    |> Enum.with_index()
    |> Enum.map(fn {{start_line, sec_num, sec_title}, idx} ->
      end_line =
        case Enum.at(section_starts, idx + 1) do
          {next_start, _, _} -> next_start - 1
          nil -> total_lines
        end

      text =
        lines
        |> Enum.slice((start_line - 1)..(end_line - 1))
        |> Enum.join("\n")

      title_info = find_title(start_line)
      structural = find_structural_context(lines, start_line)

      %Section{
        section_number: sec_num,
        title: sec_title,
        title_num: title_info.num,
        title_name: title_info.name,
        subtitle: structural.subtitle,
        chapter: structural.chapter,
        subchapter: structural.subchapter,
        start_line: start_line,
        end_line: end_line,
        text: text,
        line_count: end_line - start_line + 1
      }
    end)
  end

  defp extract_section_number(line) do
    case Regex.run(~r/SEC\.\s+(\d+)/, line) do
      [_, num] -> num
      _ -> "unknown"
    end
  end

  defp extract_section_title(line) do
    line
    |> String.replace(~r/^\s*SEC\.\s+\d+\.\s*/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp find_title(line_num) do
    Enum.find(@title_boundaries, List.last(@title_boundaries), fn %{start_line: s, end_line: e} ->
      line_num >= s and line_num <= e
    end)
  end

  defp find_structural_context(lines, section_start) do
    # Look backwards from the section start to find the nearest
    # Subtitle, Chapter, and Subchapter markers
    context_lines =
      lines
      |> Enum.slice(0..(section_start - 2))
      |> Enum.reverse()
      |> Enum.take(200)

    subtitle = find_nearest_marker(context_lines, ~r/Subtitle\s+([A-Z])[\s—–-]+(.+)/i)
    chapter = find_nearest_marker(context_lines, ~r/CHAPTER\s+(\d+)[\s—–-]+(.+)/i)
    subchapter = find_nearest_marker(context_lines, ~r/Subchapter\s+([A-Z])[\s—–-]+(.+)/i)

    %{subtitle: subtitle, chapter: chapter, subchapter: subchapter}
  end

  defp find_nearest_marker(reversed_lines, pattern) do
    Enum.find_value(reversed_lines, fn line ->
      case Regex.run(pattern, String.trim(line)) do
        [match | _] ->
          match
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        _ ->
          nil
      end
    end)
  end

  defp split_large_title(title_num, sections) do
    title_info = Enum.find(@title_boundaries, &(&1.num == title_num))

    sections
    |> Enum.group_by(fn sec ->
      cond do
        sec.subchapter -> "#{sec.subtitle || "?"} > #{sec.chapter || "?"} > #{sec.subchapter}"
        sec.chapter -> "#{sec.subtitle || "?"} > #{sec.chapter}"
        sec.subtitle -> sec.subtitle
        true -> "Other"
      end
    end)
    |> Enum.map(fn {group, group_sections} ->
      label = "Title #{to_roman(title_num)} - #{title_info.name} / #{group}"
      {label, group_sections}
    end)
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
