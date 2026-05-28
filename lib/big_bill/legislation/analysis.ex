defmodule BigBill.Legislation.Analysis do
  @moduledoc """
  Structured analysis result for a bill section or batch of sections.

  Produced by the legal-analyst subagent and stored for querying.
  """

  @type mechanism ::
          :amends_existing_law
          | :creates_new_authority
          | :appropriates_funds
          | :sets_deadline
          | :defines_terms
          | :establishes_penalty
          | :rescinds_funds
          | :modifies_eligibility
          | :creates_program
          | :terminates_program
          | :other

  @type t :: %__MODULE__{
          section_number: String.t(),
          section_title: String.t(),
          title_num: pos_integer(),
          summary: String.t(),
          mechanisms: [mechanism()],
          existing_law_modified: [String.t()],
          money: [String.t()],
          deadlines: [String.t()],
          beneficiaries: [String.t()],
          losers: [String.t()],
          buried_provisions: [String.t()],
          cross_references: [String.t()],
          tags: [String.t()],
          confidence: :high | :medium | :low,
          notes: String.t() | nil,
          raw_analysis: String.t()
        }

  defstruct [
    :section_number,
    :section_title,
    :title_num,
    :summary,
    :confidence,
    :notes,
    :raw_analysis,
    mechanisms: [],
    existing_law_modified: [],
    money: [],
    deadlines: [],
    beneficiaries: [],
    losers: [],
    buried_provisions: [],
    cross_references: [],
    tags: []
  ]
end
