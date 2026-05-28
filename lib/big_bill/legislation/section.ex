defmodule BigBill.Legislation.Section do
  @moduledoc """
  A discrete section of legislative text from the bill.

  Each section represents a single SEC. entry with its full text,
  structural position (title, subtitle, chapter), and line range
  in the source document.
  """

  @type t :: %__MODULE__{
          section_number: String.t(),
          title: String.t(),
          title_num: pos_integer(),
          title_name: String.t(),
          subtitle: String.t() | nil,
          chapter: String.t() | nil,
          subchapter: String.t() | nil,
          start_line: pos_integer(),
          end_line: pos_integer(),
          text: String.t(),
          line_count: non_neg_integer()
        }

  defstruct [
    :section_number,
    :title,
    :title_num,
    :title_name,
    :subtitle,
    :chapter,
    :subchapter,
    :start_line,
    :end_line,
    :text,
    line_count: 0
  ]
end
