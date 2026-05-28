defmodule BigBill.Search.Advanced do
  @moduledoc """
  Advanced search capabilities over the Big Beautiful Bill corpus.

  Builds on `BigBill.Search.Server` (FTS5/SQLite) and the DuckDB analytics
  database to provide scoped search, boolean query building, text-similarity
  "find related" results, aggregation counts, and drill-down into money flows,
  entities, and cross-references.

  ## Architecture

  Pure functions build queries; impure functions execute them.

  - **Query builders** (`build_query/1`, `scope_clause/1`) are pure — they
    return SQL fragments or FTS5 query strings with no side effects.
  - **Execution functions** (`search/3`, `find_related/2`, etc.) call through
    `BigBill.Search.Server` for FTS5 and open a read-only DuckDB connection
    for analytics queries.
  """

  alias BigBill.Search
  alias BigBill.Search.Server

  # -------------------------------------------------------------------
  # Types
  # -------------------------------------------------------------------

  @typedoc "Restricts search to a subset of the corpus."
  @type scope ::
          :all
          | {:title, integer()}
          | {:document, String.t()}
          | {:graph_subtree, integer()}

  @typedoc "A structured filter that maps to FTS5 query syntax."
  @type filter ::
          {:contains, String.t()}
          | {:not_contains, String.t()}
          | {:phrase, String.t()}
          | {:near, String.t(), String.t(), integer()}
          | {:field, String.t(), String.t()}
          | {:and, [filter()]}
          | {:or, [filter()]}

  @typedoc "A unified search result (same shape as `BigBill.Search.result()`)."
  @type result :: Search.result()

  @duckdb_path Path.join(
                 Application.compile_env(:big_bill, :project_root, Path.join(:code.priv_dir(:big_bill), "..")),
                 "analytics/db/big_bill.duckdb"
               )

  @stop_words MapSet.new(~w(
    the be to of and a in that have i it for not on with he as you do at this
    but his by from they we say her she or an will my one all would there their
    what so up out if about who get which go me when make can like time no just
    him know take people into year your good some could them see other than then
    now look only come its over think also back after use two how our work first
    well way even new want because any these give day most us is are was were
    been has had did does shall may section act under such than more than any
    each every upon within without through during before after between among
    federal state program fund amount secretary provided paragraph subsection
    subparagraph clause title chapter part subtitle division
  ))

  # -------------------------------------------------------------------
  # 1. Scoped Search
  # -------------------------------------------------------------------

  @doc """
  Search the FTS5 index restricted to a scope.

  ## Options

    * `:limit` — max results (default 50)
    * `:offset` — result offset (default 0)

  ## Examples

      Advanced.search("medicaid", :all)
      Advanced.search("work requirements", {:title, 1})
      Advanced.search("rescission", {:document, "title_07a_tax_ch1_ch2.md"})
  """
  @spec search(String.t(), scope(), keyword()) :: [result()]
  def search(query, scope \\ :all, opts \\ []) do
    query = String.trim(query)
    if query == "", do: [], else: do_scoped_search(query, scope, opts)
  end

  defp do_scoped_search(query, scope, opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    fts_query = sanitize_fts_input(query)

    Server.call_with_conn(fn conn ->
      results =
        scoped_bill_search(conn, fts_query, scope) ++
          scoped_analysis_search(conn, fts_query, scope) ++
          scoped_graph_search(conn, fts_query, scope) ++
          scoped_document_search(conn, fts_query, scope)

      results
      |> Enum.sort_by(& &1.rank)
      |> Enum.drop(offset)
      |> Enum.take(limit)
    end)
  end

  defp scoped_bill_search(conn, fts_query, scope) do
    {where_extra, extra_params} = bill_scope_clause(scope)

    sql = """
    SELECT section_number, title, snippet(bill_sections_fts, 3, '<mark>', '</mark>', '...', 40), rank
    FROM bill_sections_fts
    WHERE bill_sections_fts MATCH ?1 #{where_extra}
    ORDER BY rank
    LIMIT 50
    """

    query_fts(conn, sql, [fts_query | extra_params], fn [sec_num, title, snippet, rank] ->
      %{
        source: :bill,
        title: "SEC. #{sec_num} - #{title}",
        snippet: snippet,
        section_number: sec_num,
        node_id: nil,
        rank: rank
      }
    end)
  end

  defp scoped_analysis_search(conn, fts_query, scope) do
    {where_extra, extra_params} = analysis_scope_clause(scope)

    sql = """
    SELECT source_file, section_number, snippet(analysis_fts, 2, '<mark>', '</mark>', '...', 40), rank
    FROM analysis_fts
    WHERE analysis_fts MATCH ?1 #{where_extra}
    ORDER BY rank
    LIMIT 50
    """

    query_fts(conn, sql, [fts_query | extra_params], fn [source_file, section_number, snippet, rank] ->
      %{
        source: :analysis,
        title: format_analysis_title(source_file),
        snippet: snippet,
        section_number: section_number,
        node_id: nil,
        rank: rank
      }
    end)
  end

  defp scoped_graph_search(conn, fts_query, scope) do
    case scope do
      {:title, _} -> []
      {:document, _} -> []
      {:graph_subtree, root_id} -> graph_subtree_search(conn, fts_query, root_id)
      :all -> unscoped_graph_search(conn, fts_query)
    end
  end

  defp unscoped_graph_search(conn, fts_query) do
    sql = """
    SELECT node_id, node_type, title, snippet(graph_nodes_fts, 3, '<mark>', '</mark>', '...', 40), rank
    FROM graph_nodes_fts
    WHERE graph_nodes_fts MATCH ?1
    ORDER BY rank
    LIMIT 50
    """

    query_fts(conn, sql, [fts_query], &map_graph_row/1)
  end

  defp graph_subtree_search(conn, fts_query, root_id) do
    descendant_ids = get_graph_descendants(root_id)
    all_ids = [root_id | descendant_ids]

    # FTS5 doesn't support IN clauses well, so we fetch all matches and filter
    sql = """
    SELECT node_id, node_type, title, snippet(graph_nodes_fts, 3, '<mark>', '</mark>', '...', 40), rank
    FROM graph_nodes_fts
    WHERE graph_nodes_fts MATCH ?1
    ORDER BY rank
    LIMIT 200
    """

    id_set = MapSet.new(all_ids)

    query_fts(conn, sql, [fts_query], &map_graph_row/1)
    |> Enum.filter(fn r -> r.node_id in id_set end)
  end

  defp scoped_document_search(conn, fts_query, scope) do
    case scope do
      {:title, _} -> []
      {:document, _} -> []
      _ -> unscoped_document_search(conn, fts_query)
    end
  end

  defp unscoped_document_search(conn, fts_query) do
    sql = """
    SELECT doc_id, node_id, filename, snippet(documents_fts, 3, '<mark>', '</mark>', '...', 40), rank
    FROM documents_fts
    WHERE documents_fts MATCH ?1
    ORDER BY rank
    LIMIT 50
    """

    query_fts(conn, sql, [fts_query], fn [_doc_id, node_id, filename, snippet, rank] ->
      %{
        source: :document,
        title: filename,
        snippet: snippet,
        section_number: nil,
        node_id: parse_int(node_id),
        rank: rank
      }
    end)
  end

  # Scope clause builders — return {sql_fragment, params_list}
  # The param indices start at ?2 since ?1 is always the FTS query.

  defp bill_scope_clause(:all), do: {"", []}

  defp bill_scope_clause({:title, title_num}) when is_integer(title_num) do
    {prefix_lo, prefix_hi} = section_prefix_range(title_num)
    {"AND section_number >= ?2 AND section_number <= ?3", [prefix_lo, prefix_hi]}
  end

  defp bill_scope_clause({:document, _}), do: {"", []}
  defp bill_scope_clause({:graph_subtree, _}), do: {"", []}

  defp analysis_scope_clause(:all), do: {"", []}

  defp analysis_scope_clause({:title, title_num}) when is_integer(title_num) do
    # Analysis files follow pattern: title_NN_*.md
    prefix = title_num |> Integer.to_string() |> String.pad_leading(2, "0")
    pattern = "title_#{prefix}%"
    {"AND source_file LIKE ?2", [pattern]}
  end

  defp analysis_scope_clause({:document, source_file}) when is_binary(source_file) do
    safe_file = sanitize_identifier(source_file)
    {"AND source_file = ?2", [safe_file]}
  end

  defp analysis_scope_clause({:graph_subtree, _}), do: {"", []}

  # Section numbers are prefixed by title: title 1 => 10101-10699, title 7 => 70001-79999, etc.
  # This is an approximation; the loader.py TITLE_DATA has exact ranges.
  defp section_prefix_range(title_num) when is_integer(title_num) do
    lo = Integer.to_string(title_num * 10000 + 1)
    hi = Integer.to_string((title_num + 1) * 10000 - 1)
    {lo, hi}
  end

  # -------------------------------------------------------------------
  # 2. Boolean Query Builder
  # -------------------------------------------------------------------

  @doc """
  Build an FTS5 query string from a list of structured filters.

  ## Examples

      iex> Advanced.build_query([{:contains, "medicaid"}, {:not_contains, "dental"}])
      "medicaid NOT dental"

      iex> Advanced.build_query([{:phrase, "work requirements"}])
      ~S("work requirements")

      iex> Advanced.build_query([{:near, "medicaid", "work", 5}])
      "NEAR(medicaid work, 5)"

      iex> Advanced.build_query([{:field, "title", "agriculture"}])
      "title:agriculture"

      iex> Advanced.build_query([{:or, [{:contains, "snap"}, {:contains, "medicaid"}]}])
      "(snap OR medicaid)"
  """
  @spec build_query([filter()]) :: String.t()
  def build_query(filters) when is_list(filters) do
    filters
    |> Enum.map(&filter_to_fts5/1)
    |> Enum.join(" AND ")
  end

  @spec filter_to_fts5(filter()) :: String.t()
  defp filter_to_fts5({:contains, term}) do
    sanitize_token(term)
  end

  defp filter_to_fts5({:not_contains, term}) do
    "NOT #{sanitize_token(term)}"
  end

  defp filter_to_fts5({:phrase, phrase}) do
    safe = String.replace(phrase, "\"", "")
    "\"#{safe}\""
  end

  defp filter_to_fts5({:near, term_a, term_b, distance})
       when is_binary(term_a) and is_binary(term_b) and is_integer(distance) do
    a = sanitize_token(term_a)
    b = sanitize_token(term_b)
    d = max(1, distance)
    "NEAR(#{a} #{b}, #{d})"
  end

  defp filter_to_fts5({:field, column, term})
       when is_binary(column) and is_binary(term) do
    safe_col = sanitize_identifier(column)
    safe_term = sanitize_token(term)
    "#{safe_col}:#{safe_term}"
  end

  defp filter_to_fts5({:and, sub_filters}) when is_list(sub_filters) do
    inner =
      sub_filters
      |> Enum.map(&filter_to_fts5/1)
      |> Enum.join(" AND ")

    "(#{inner})"
  end

  defp filter_to_fts5({:or, sub_filters}) when is_list(sub_filters) do
    inner =
      sub_filters
      |> Enum.map(&filter_to_fts5/1)
      |> Enum.join(" OR ")

    "(#{inner})"
  end

  @doc """
  Search using structured boolean filters with optional scope.

  Combines `build_query/1` with `search/3` for a convenient API.
  """
  @spec search_filters([filter()], scope(), keyword()) :: [result()]
  def search_filters(filters, scope \\ :all, opts \\ []) do
    fts_query = build_query(filters)
    if fts_query == "", do: [], else: search(fts_query, scope, opts)
  end

  # -------------------------------------------------------------------
  # 3. Find Related (TF-IDF-like via FTS5)
  # -------------------------------------------------------------------

  @doc """
  Find content related to a given section or graph node by extracting
  distinctive terms and querying FTS5 with them.

  ## Options

    * `:limit` — max results (default 20)
    * `:min_terms` — minimum distinctive terms to use (default 5)
    * `:max_terms` — maximum distinctive terms to use (default 10)

  ## Examples

      Advanced.find_related({:section, "10101"})
      Advanced.find_related({:node, 42}, limit: 10)
  """
  @spec find_related({:section, String.t()} | {:node, integer()}, keyword()) :: [result()]
  def find_related(source, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    max_terms = Keyword.get(opts, :max_terms, 10)
    min_terms = Keyword.get(opts, :min_terms, 5)

    text = fetch_source_text(source)

    case text do
      nil ->
        []

      "" ->
        []

      content ->
        terms = extract_distinctive_terms(content, max_terms)

        if length(terms) < min_terms do
          []
        else
          fts_query = Enum.join(terms, " OR ")

          results =
            Server.call_with_conn(fn conn ->
              search_all_tables(conn, fts_query)
            end)

          results
          |> reject_source(source)
          |> Enum.sort_by(& &1.rank)
          |> Enum.take(limit)
        end
    end
  end

  defp fetch_source_text({:section, section_number}) when is_binary(section_number) do
    safe_sec = sanitize_identifier(section_number)

    Server.call_with_conn(fn conn ->
      sql = "SELECT text FROM bill_sections_fts WHERE section_number = ?1 LIMIT 1"

      case query_fts(conn, sql, [safe_sec], fn [text] -> text end) do
        [text | _] -> text
        [] -> nil
      end
    end)
  end

  defp fetch_source_text({:node, node_id}) when is_integer(node_id) do
    id_str = Integer.to_string(node_id)

    Server.call_with_conn(fn conn ->
      sql = "SELECT title, description FROM graph_nodes_fts WHERE node_id = ?1 LIMIT 1"

      case query_fts(conn, sql, [id_str], fn [title, desc] -> "#{title} #{desc}" end) do
        [text | _] -> text
        [] -> nil
      end
    end)
  end

  @doc """
  Extract the most distinctive (non-stop-word, longer) terms from text.

  Returns up to `max_count` terms sorted by length descending (longer terms
  tend to be more specific).
  """
  @spec extract_distinctive_terms(String.t(), non_neg_integer()) :: [String.t()]
  def extract_distinctive_terms(text, max_count \\ 10) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s'-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn word ->
      String.length(word) < 4 or MapSet.member?(@stop_words, word)
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {word, freq} -> {-freq, -String.length(word)} end)
    |> Enum.map(fn {word, _freq} -> word end)
    |> Enum.uniq()
    |> Enum.take(max_count)
  end

  defp reject_source(results, {:section, sec_num}) do
    Enum.reject(results, fn r -> r.section_number == sec_num end)
  end

  defp reject_source(results, {:node, node_id}) do
    Enum.reject(results, fn r -> r.node_id == node_id end)
  end

  defp search_all_tables(conn, fts_query) do
    bill =
      query_fts(
        conn,
        """
        SELECT section_number, title, snippet(bill_sections_fts, 3, '<mark>', '</mark>', '...', 40), rank
        FROM bill_sections_fts WHERE bill_sections_fts MATCH ?1 ORDER BY rank LIMIT 50
        """,
        [fts_query],
        fn [sec_num, title, snippet, rank] ->
          %{source: :bill, title: "SEC. #{sec_num} - #{title}", snippet: snippet,
            section_number: sec_num, node_id: nil, rank: rank}
        end
      )

    analysis =
      query_fts(
        conn,
        """
        SELECT source_file, section_number, snippet(analysis_fts, 2, '<mark>', '</mark>', '...', 40), rank
        FROM analysis_fts WHERE analysis_fts MATCH ?1 ORDER BY rank LIMIT 50
        """,
        [fts_query],
        fn [source_file, section_number, snippet, rank] ->
          %{source: :analysis, title: format_analysis_title(source_file), snippet: snippet,
            section_number: section_number, node_id: nil, rank: rank}
        end
      )

    graph =
      query_fts(
        conn,
        """
        SELECT node_id, node_type, title, snippet(graph_nodes_fts, 3, '<mark>', '</mark>', '...', 40), rank
        FROM graph_nodes_fts WHERE graph_nodes_fts MATCH ?1 ORDER BY rank LIMIT 50
        """,
        [fts_query],
        &map_graph_row/1
      )

    bill ++ analysis ++ graph
  end

  # -------------------------------------------------------------------
  # 4. Aggregation Queries
  # -------------------------------------------------------------------

  @doc """
  Count how many bill sections match a term, grouped by a field.

  The `group_field` must be one of: `"title"`, `"section_number"`, `"source_file"`.

  Returns a list of `{field_value, count}` tuples sorted by count descending.

  ## Examples

      Advanced.count_by_field("alien eligibility", "title")
      #=> [{"Agriculture, Nutrition, and Forestry", 12}, {"Judiciary", 8}, ...]
  """
  @spec count_by_field(String.t(), String.t()) :: [{String.t(), integer()}]
  def count_by_field(query, group_field) when is_binary(query) and is_binary(group_field) do
    query = String.trim(query)
    if query == "", do: [], else: do_count_by_field(query, group_field)
  end

  defp do_count_by_field(query, "title") do
    # Group bill section matches by title number, then look up title names
    fts_query = sanitize_fts_input(query)

    section_counts =
      Server.call_with_conn(fn conn ->
        sql = """
        SELECT section_number, rank
        FROM bill_sections_fts
        WHERE bill_sections_fts MATCH ?1
        ORDER BY rank
        LIMIT 500
        """

        query_fts(conn, sql, [fts_query], fn [sec_num, _rank] -> sec_num end)
      end)

    title_names = title_lookup()

    section_counts
    |> Enum.map(fn sec_num ->
      title_num = infer_title_from_section(sec_num)
      Map.get(title_names, title_num, "Unknown Title #{title_num}")
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_name, count} -> -count end)
  end

  defp do_count_by_field(query, "source_file") do
    fts_query = sanitize_fts_input(query)

    Server.call_with_conn(fn conn ->
      # FTS5 doesn't support GROUP BY directly, so we fetch and group in Elixir
      rows_sql = """
      SELECT source_file
      FROM analysis_fts
      WHERE analysis_fts MATCH ?1
      LIMIT 500
      """

      query_fts(conn, rows_sql, [fts_query], fn [source_file] -> source_file end)
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_name, count} -> -count end)
  end

  defp do_count_by_field(query, "section_number") do
    fts_query = sanitize_fts_input(query)

    Server.call_with_conn(fn conn ->
      sql = """
      SELECT section_number
      FROM bill_sections_fts
      WHERE bill_sections_fts MATCH ?1
      LIMIT 500
      """

      query_fts(conn, sql, [fts_query], fn [sec_num] -> sec_num end)
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_name, count} -> -count end)
  end

  defp do_count_by_field(_query, _unknown_field), do: []

  # -------------------------------------------------------------------
  # 5. Drill-down Functions (DuckDB analytics)
  # -------------------------------------------------------------------

  @doc """
  Get all money flow records within a scope from the DuckDB analytics database.

  Returns a list of maps with keys: `section_number`, `title_num`, `amount_text`,
  `amount_dollars`, `amount_unit`, `direction`, `source_law`, `notes`.
  """
  @spec money_in_scope(scope()) :: [map()]
  def money_in_scope(scope) do
    with_duckdb(fn conn ->
      {where, params} = duckdb_scope_clause(scope, "m")

      sql = """
      SELECT m.section_number, m.title_num, m.amount_text, m.amount_dollars,
             m.amount_unit, m.direction, m.source_law, m.notes,
             t.title_name
      FROM money_flows m
      JOIN titles t ON m.title_num = t.title_num
      #{where}
      ORDER BY m.amount_dollars DESC NULLS LAST
      """

      duckdb_query(conn, sql, params, fn row ->
        %{
          section_number: Enum.at(row, 0),
          title_num: Enum.at(row, 1),
          amount_text: Enum.at(row, 2),
          amount_dollars: Enum.at(row, 3),
          amount_unit: Enum.at(row, 4),
          direction: Enum.at(row, 5),
          source_law: Enum.at(row, 6),
          notes: Enum.at(row, 7),
          title_name: Enum.at(row, 8)
        }
      end)
    end)
  end

  @doc """
  Get all entity (winners/losers) records within a scope from DuckDB.

  Returns a list of maps with keys: `section_number`, `title_num`, `entity_name`,
  `entity_type`, `outcome`, `detail`.
  """
  @spec entities_in_scope(scope()) :: [map()]
  def entities_in_scope(scope) do
    with_duckdb(fn conn ->
      {where, params} = duckdb_scope_clause(scope, "e")

      sql = """
      SELECT e.section_number, e.title_num, e.entity_name, e.entity_type,
             e.outcome, e.detail, t.title_name
      FROM entities e
      JOIN titles t ON e.title_num = t.title_num
      #{where}
      ORDER BY e.outcome, e.entity_name
      """

      duckdb_query(conn, sql, params, fn row ->
        %{
          section_number: Enum.at(row, 0),
          title_num: Enum.at(row, 1),
          entity_name: Enum.at(row, 2),
          entity_type: Enum.at(row, 3),
          outcome: Enum.at(row, 4),
          detail: Enum.at(row, 5),
          title_name: Enum.at(row, 6)
        }
      end)
    end)
  end

  @doc """
  Get cross-references from and to a given section number from DuckDB.

  Returns a list of maps with keys: `from_section`, `to_section`, `ref_type`,
  `ref_text`, `direction` (`:outgoing` or `:incoming`).
  """
  @spec cross_refs(String.t()) :: [map()]
  def cross_refs(section_number) when is_binary(section_number) do
    safe_sec = sanitize_identifier(section_number)

    with_duckdb(fn conn ->
      outgoing_sql = """
      SELECT from_section, to_section, ref_type, ref_text
      FROM cross_references
      WHERE from_section = $1
      ORDER BY to_section
      """

      incoming_sql = """
      SELECT from_section, to_section, ref_type, ref_text
      FROM cross_references
      WHERE to_section = $1
      ORDER BY from_section
      """

      outgoing =
        duckdb_query(conn, outgoing_sql, [safe_sec], fn row ->
          %{
            from_section: Enum.at(row, 0),
            to_section: Enum.at(row, 1),
            ref_type: Enum.at(row, 2),
            ref_text: Enum.at(row, 3),
            direction: :outgoing
          }
        end)

      incoming =
        duckdb_query(conn, incoming_sql, [safe_sec], fn row ->
          %{
            from_section: Enum.at(row, 0),
            to_section: Enum.at(row, 1),
            ref_type: Enum.at(row, 2),
            ref_text: Enum.at(row, 3),
            direction: :incoming
          }
        end)

      outgoing ++ incoming
    end)
  end

  # -------------------------------------------------------------------
  # DuckDB scope clause builder
  # -------------------------------------------------------------------

  defp duckdb_scope_clause(:all, _alias), do: {"", []}

  defp duckdb_scope_clause({:title, title_num}, alias_name) when is_integer(title_num) do
    {"WHERE #{alias_name}.title_num = $1", [title_num]}
  end

  defp duckdb_scope_clause({:document, source_file}, alias_name) when is_binary(source_file) do
    safe = sanitize_identifier(source_file)
    # Join through sections to filter by source_file
    {"JOIN sections s ON #{alias_name}.section_number = s.section_number WHERE s.source_file = $1",
     [safe]}
  end

  defp duckdb_scope_clause({:graph_subtree, _root_id}, _alias), do: {"", []}

  # -------------------------------------------------------------------
  # DuckDB connection helper
  # -------------------------------------------------------------------

  defp with_duckdb(fun) when is_function(fun, 1) do
    db_path = duckdb_path()

    if File.exists?(db_path) do
      case Duckdbex.open(db_path, %{access_mode: :read_only}) do
        {:ok, db} ->
          case Duckdbex.connection(db) do
            {:ok, conn} ->
              try do
                fun.(conn)
              rescue
                e -> {:error, Exception.message(e)}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      []
    end
  end

  defp duckdb_path do
    @duckdb_path
  end

  defp duckdb_query(conn, sql, params, mapper) do
    case Duckdbex.query(conn, sql, params) do
      {:ok, result} ->
        rows = Duckdbex.fetch_all(result)
        Enum.map(rows, mapper)

      {:error, _reason} ->
        []
    end
  rescue
    _ -> []
  end

  # -------------------------------------------------------------------
  # Graph subtree traversal
  # -------------------------------------------------------------------

  defp get_graph_descendants(root_id) do
    graph_path = Path.join(:code.priv_dir(:big_bill), "../docs/graph-data.json")

    if File.exists?(graph_path) do
      {:ok, json} = File.read(graph_path)
      {:ok, data} = Jason.decode(json)
      edges = Map.get(data, "edges", [])

      # Build adjacency list (from -> [to])
      adj =
        Enum.reduce(edges, %{}, fn edge, acc ->
          from = edge["from_node_id"]
          to = edge["to_node_id"]
          Map.update(acc, from, [to], fn existing -> [to | existing] end)
        end)

      # BFS from root_id
      bfs(adj, [root_id], MapSet.new([root_id]))
      |> MapSet.delete(root_id)
      |> MapSet.to_list()
    else
      []
    end
  end

  defp bfs(_adj, [], visited), do: visited

  defp bfs(adj, queue, visited) do
    next_queue =
      Enum.flat_map(queue, fn node ->
        children = Map.get(adj, node, [])
        Enum.reject(children, &MapSet.member?(visited, &1))
      end)

    new_visited = Enum.reduce(next_queue, visited, &MapSet.put(&2, &1))
    bfs(adj, next_queue, new_visited)
  end

  # -------------------------------------------------------------------
  # Title lookup (static from loader.py TITLE_DATA)
  # -------------------------------------------------------------------

  @title_data %{
    1 => "Agriculture, Nutrition, and Forestry",
    2 => "Armed Services",
    3 => "Banking, Housing, and Urban Affairs",
    4 => "Commerce, Science, and Transportation",
    5 => "Energy and Natural Resources",
    6 => "Environment and Public Works",
    7 => "Finance",
    8 => "Health, Education, Labor, and Pensions",
    9 => "Homeland Security and Governmental Affairs",
    10 => "Judiciary"
  }

  defp title_lookup, do: @title_data

  defp infer_title_from_section(section_number) when is_binary(section_number) do
    case Integer.parse(section_number) do
      {num, _} when num >= 10000 -> div(num, 10000)
      {num, _} when num >= 1000 -> div(num, 1000)
      _ -> 0
    end
  end

  defp infer_title_from_section(_), do: 0

  # -------------------------------------------------------------------
  # Shared helpers (mirrored from Search for use outside GenServer)
  # -------------------------------------------------------------------

  defp query_fts(conn, sql, params, mapper) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, params)
        rows = fetch_all_rows(conn, stmt, [])
        :ok = Exqlite.Sqlite3.release(conn, stmt)
        Enum.map(rows, mapper)

      {:error, _reason} ->
        []
    end
  rescue
    _ -> []
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp map_graph_row([node_id, node_type, title, snippet, rank]) do
    %{
      source: :graph_node,
      title: "[#{node_type}] #{title}",
      snippet: snippet,
      section_number: nil,
      node_id: parse_int(node_id),
      rank: rank
    }
  end

  defp format_analysis_title(filename) do
    filename
    |> String.replace(~r/\.md$/, "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  # -------------------------------------------------------------------
  # Input sanitization
  # -------------------------------------------------------------------

  @doc false
  @spec sanitize_fts_input(String.t()) :: String.t()
  def sanitize_fts_input(query) do
    query
    |> String.replace(~r/["\(\)\*\:\^]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(fn token -> "\"#{token}\"" end)
    |> Enum.join(" ")
  end

  defp sanitize_token(term) do
    term
    |> String.replace(~r/[^a-zA-Z0-9_\-']/, "")
    |> case do
      "" -> "unknown"
      safe -> safe
    end
  end

  defp sanitize_identifier(value) do
    String.replace(value, ~r/[^a-zA-Z0-9_.\-]/, "")
  end

  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
