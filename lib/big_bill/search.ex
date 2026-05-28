defmodule BigBill.Search do
  @moduledoc """
  Full-text search across bill sections, analysis files, decision graph nodes,
  and attached documents using SQLite FTS5.

  Uses Exqlite directly (not Ecto) for raw FTS5 control. The SQLite connection
  is held open by `BigBill.Search.Server` and accessed through that GenServer.
  """

  alias BigBill.Legislation.Parser
  alias BigBill.Search.Server

  @type source :: :bill | :analysis | :graph_node | :document

  @type result :: %{
          source: source(),
          title: String.t(),
          snippet: String.t(),
          section_number: String.t() | nil,
          node_id: integer() | nil,
          rank: float()
        }

  @db_path Path.join(:code.priv_dir(:big_bill), "search.db")

  @doc "Return the path to the SQLite database file."
  @spec db_path() :: String.t()
  def db_path, do: @db_path

  @doc "Check whether the search index has been populated."
  @spec index_exists?() :: boolean()
  def index_exists? do
    File.exists?(@db_path) and File.stat!(@db_path).size > 0
  end

  # -------------------------------------------------------------------
  # Schema creation
  # -------------------------------------------------------------------

  @doc "Create FTS5 virtual tables in the given database connection."
  @spec create_tables(reference()) :: :ok
  def create_tables(conn) do
    statements = [
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS bill_sections_fts USING fts5(
        section_number,
        title,
        subtitle,
        text,
        tokenize='porter unicode61'
      )
      """,
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS analysis_fts USING fts5(
        source_file,
        section_number,
        content,
        tokenize='porter unicode61'
      )
      """,
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS graph_nodes_fts USING fts5(
        node_id,
        node_type,
        title,
        description,
        tokenize='porter unicode61'
      )
      """,
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
        doc_id,
        node_id,
        filename,
        description,
        tokenize='porter unicode61'
      )
      """
    ]

    Enum.each(statements, fn sql ->
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    end)

    :ok
  end

  # -------------------------------------------------------------------
  # Index building
  # -------------------------------------------------------------------

  @doc """
  Build (or rebuild) the full-text search index.

  Drops existing data, re-creates the FTS5 tables, and populates them
  from the bill text, analysis markdown files, graph nodes, and documents.
  """
  @spec build_index() :: :ok
  def build_index do
    Server.rebuild()
  end

  @doc "Populate all FTS5 tables using the given open connection."
  @spec populate(reference()) :: :ok
  def populate(conn) do
    drop_all(conn)
    create_tables(conn)
    index_bill_sections(conn)
    index_analysis_files(conn)
    index_graph_nodes(conn)
    index_documents(conn)
    :ok
  end

  # -------------------------------------------------------------------
  # Search
  # -------------------------------------------------------------------

  @doc "Search all tables and return unified results sorted by rank."
  @spec search(String.t()) :: [result()]
  def search(query) when is_binary(query) do
    query = String.trim(query)
    if query == "", do: [], else: Server.search(query, :all)
  end

  @doc "Search a single facet, or `:all` for unified results."
  @spec search(String.t(), source() | :all) :: [result()]
  def search(query, facet) when is_binary(query) and is_atom(facet) do
    query = String.trim(query)
    if query == "", do: [], else: Server.search(query, facet)
  end

  @doc "Return result counts per facet for the given query."
  @spec facet_counts(String.t()) :: %{source() => non_neg_integer()}
  def facet_counts(query) when is_binary(query) do
    Server.facet_counts(query)
  end

  @doc """
  Fetch the full content for a search result, suitable for display in a modal.

  Returns a map with :source, :title, :section_number, :node_id, and :content (full text).
  """
  @spec get_full_content(result()) :: map()
  def get_full_content(%{source: :bill, section_number: sec_num}) when is_binary(sec_num) do
    bill_path = Path.join(:code.priv_dir(:big_bill), "../bigbill.txt")

    section =
      if File.exists?(bill_path) do
        Parser.parse(bill_path)
        |> Enum.find(&(&1.section_number == sec_num))
      end

    if section do
      %{
        source: :bill,
        title: "SEC. #{section.section_number} — #{section.title}",
        section_number: sec_num,
        node_id: nil,
        meta: %{
          title_name: section.title_name,
          subtitle: section.subtitle,
          chapter: section.chapter,
          lines: "#{section.start_line}–#{section.end_line}"
        },
        content: section.text
      }
    else
      %{source: :bill, title: "SEC. #{sec_num}", section_number: sec_num, node_id: nil, meta: %{}, content: "Section not found."}
    end
  end

  def get_full_content(%{source: :graph_node, node_id: node_id}) when not is_nil(node_id) do
    graph_path = Path.join(:code.priv_dir(:big_bill), "../docs/graph-data.json")

    node =
      if File.exists?(graph_path) do
        {:ok, json} = File.read(graph_path)
        {:ok, data} = Jason.decode(json)

        data
        |> Map.get("nodes", [])
        |> Enum.find(&(to_string(&1["id"]) == to_string(node_id)))
      end

    if node do
      %{
        source: :graph_node,
        title: node["title"] || "Node ##{node_id}",
        section_number: nil,
        node_id: node_id,
        meta: %{
          type: node["node_type"],
          status: node["status"],
          confidence: node["confidence"]
        },
        content: node["description"] || node["title"] || ""
      }
    else
      %{source: :graph_node, title: "Node ##{node_id}", section_number: nil, node_id: node_id, meta: %{}, content: "Node not found."}
    end
  end

  def get_full_content(%{source: :analysis, title: title}) do
    analysis_dir = Path.join(:code.priv_dir(:big_bill), "../analysis")
    # Title contains the filename
    filename = Enum.find(File.ls!(analysis_dir), fn f -> String.contains?(title, f) end)

    content =
      if filename do
        File.read!(Path.join(analysis_dir, filename))
      else
        "Analysis file not found."
      end

    %{source: :analysis, title: title, section_number: nil, node_id: nil, meta: %{}, content: content}
  end

  def get_full_content(%{source: :document} = result) do
    %{source: :document, title: result.title, section_number: nil, node_id: nil, meta: %{}, content: result.snippet || ""}
  end

  def get_full_content(result) do
    %{source: result[:source], title: result[:title] || "", section_number: nil, node_id: nil, meta: %{}, content: result[:snippet] || ""}
  end

  # -------------------------------------------------------------------
  # Query execution (called by Server with the open connection)
  # -------------------------------------------------------------------

  @doc false
  @spec execute_search(reference(), String.t(), source() | :all) :: [result()]
  def execute_search(conn, query, facet) do
    fts_query = sanitize_fts_query(query)

    results =
      case facet do
        :all ->
          search_bill(conn, fts_query, query) ++
            search_analysis(conn, fts_query) ++
            search_graph_nodes(conn, fts_query) ++
            search_documents(conn, fts_query)

        :bill ->
          search_bill(conn, fts_query, query)

        :analysis ->
          search_analysis(conn, fts_query)

        :graph_node ->
          search_graph_nodes(conn, fts_query)

        :document ->
          search_documents(conn, fts_query)
      end

    results
    |> Enum.sort_by(& &1.rank)
    |> Enum.take(50)
  end

  @doc false
  @spec execute_facet_counts(reference(), String.t()) :: %{source() => non_neg_integer()}
  def execute_facet_counts(conn, query) do
    fts_query = sanitize_fts_query(query)

    %{
      bill: count_matches(conn, "bill_sections_fts", fts_query),
      analysis: count_matches(conn, "analysis_fts", fts_query),
      graph_node: count_matches(conn, "graph_nodes_fts", fts_query),
      document: count_matches(conn, "documents_fts", fts_query)
    }
  end

  # -------------------------------------------------------------------
  # Private — indexing
  # -------------------------------------------------------------------

  defp drop_all(conn) do
    tables = ~w(bill_sections_fts analysis_fts graph_nodes_fts documents_fts)

    Enum.each(tables, fn table ->
      Exqlite.Sqlite3.execute(conn, "DROP TABLE IF EXISTS #{table}")
    end)
  end

  defp index_bill_sections(conn) do
    bill_path = Path.join(:code.priv_dir(:big_bill), "../bigbill.txt")

    if File.exists?(bill_path) do
      sections = Parser.parse(bill_path)

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          conn,
          "INSERT INTO bill_sections_fts (section_number, title, subtitle, text) VALUES (?1, ?2, ?3, ?4)"
        )

      Enum.each(sections, fn sec ->
        :ok =
          Exqlite.Sqlite3.bind(stmt, [
            sec.section_number,
            sec.title,
            sec.subtitle || "",
            sec.text
          ])

        :done = Exqlite.Sqlite3.step(conn, stmt)
        :ok = Exqlite.Sqlite3.reset(stmt)
      end)

      :ok = Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp index_analysis_files(conn) do
    analysis_dir = Path.join(:code.priv_dir(:big_bill), "../analysis")

    if File.dir?(analysis_dir) do
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          conn,
          "INSERT INTO analysis_fts (source_file, section_number, content) VALUES (?1, ?2, ?3)"
        )

      analysis_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.each(fn filename ->
        content = File.read!(Path.join(analysis_dir, filename))
        section_number = extract_section_from_filename(filename)

        :ok = Exqlite.Sqlite3.bind(stmt, [filename, section_number, content])
        :done = Exqlite.Sqlite3.step(conn, stmt)
        :ok = Exqlite.Sqlite3.reset(stmt)
      end)

      :ok = Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp index_graph_nodes(conn) do
    graph_path = Path.join(:code.priv_dir(:big_bill), "../docs/graph-data.json")

    if File.exists?(graph_path) do
      {:ok, json} = File.read(graph_path)
      {:ok, data} = Jason.decode(json)
      nodes = Map.get(data, "nodes", [])

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          conn,
          "INSERT INTO graph_nodes_fts (node_id, node_type, title, description) VALUES (?1, ?2, ?3, ?4)"
        )

      Enum.each(nodes, fn node ->
        :ok =
          Exqlite.Sqlite3.bind(stmt, [
            to_string(node["id"]),
            node["node_type"] || "",
            node["title"] || "",
            node["description"] || ""
          ])

        :done = Exqlite.Sqlite3.step(conn, stmt)
        :ok = Exqlite.Sqlite3.reset(stmt)
      end)

      :ok = Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp index_documents(conn) do
    graph_path = Path.join(:code.priv_dir(:big_bill), "../docs/graph-data.json")

    if File.exists?(graph_path) do
      {:ok, json} = File.read(graph_path)
      {:ok, data} = Jason.decode(json)
      docs = Map.get(data, "documents", [])

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          conn,
          "INSERT INTO documents_fts (doc_id, node_id, filename, description) VALUES (?1, ?2, ?3, ?4)"
        )

      Enum.each(docs, fn doc ->
        :ok =
          Exqlite.Sqlite3.bind(stmt, [
            to_string(doc["id"]),
            to_string(doc["node_id"] || ""),
            doc["original_filename"] || "",
            doc["description"] || ""
          ])

        :done = Exqlite.Sqlite3.step(conn, stmt)
        :ok = Exqlite.Sqlite3.reset(stmt)
      end)

      :ok = Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp extract_section_from_filename(filename) do
    case Regex.run(~r/title_(\d+)/, filename) do
      [_, num] -> num
      _ -> ""
    end
  end

  # -------------------------------------------------------------------
  # Private — searching
  # -------------------------------------------------------------------

  defp search_bill(conn, fts_query, raw_query) do
    # Boost exact section number matches
    exact_section_results = search_exact_section(conn, raw_query)

    fts_results =
      query_fts(
        conn,
        """
        SELECT section_number, title, snippet(bill_sections_fts, 3, '<mark>', '</mark>', '...', 40),
               rank
        FROM bill_sections_fts
        WHERE bill_sections_fts MATCH ?1
        ORDER BY rank
        LIMIT 50
        """,
        [fts_query],
        fn [sec_num, title, snippet, rank] ->
          %{
            source: :bill,
            title: "SEC. #{sec_num} - #{title}",
            snippet: snippet,
            section_number: sec_num,
            node_id: nil,
            rank: rank
          }
        end
      )

    # Merge: exact section matches get boosted rank
    boosted =
      Enum.map(exact_section_results, fn r ->
        %{r | rank: r.rank - 100.0}
      end)

    dedup_results(boosted ++ fts_results)
  end

  defp search_exact_section(conn, raw_query) do
    # Check if the query looks like a section number
    section_num =
      case Regex.run(~r/^(?:SEC\.?\s*)?(\d+)$/, String.trim(raw_query)) do
        [_, num] -> num
        _ -> nil
      end

    if section_num do
      query_fts(
        conn,
        """
        SELECT section_number, title, snippet(bill_sections_fts, 3, '<mark>', '</mark>', '...', 40),
               rank
        FROM bill_sections_fts
        WHERE section_number = ?1
        LIMIT 5
        """,
        [section_num],
        fn [sec_num, title, snippet, rank] ->
          %{
            source: :bill,
            title: "SEC. #{sec_num} - #{title}",
            snippet: snippet,
            section_number: sec_num,
            node_id: nil,
            rank: rank || -200.0
          }
        end
      )
    else
      []
    end
  end

  defp search_analysis(conn, fts_query) do
    query_fts(
      conn,
      """
      SELECT source_file, section_number, snippet(analysis_fts, 2, '<mark>', '</mark>', '...', 40),
             rank
      FROM analysis_fts
      WHERE analysis_fts MATCH ?1
      ORDER BY rank
      LIMIT 50
      """,
      [fts_query],
      fn [source_file, section_number, snippet, rank] ->
        %{
          source: :analysis,
          title: format_analysis_title(source_file),
          snippet: snippet,
          section_number: section_number,
          node_id: nil,
          rank: rank
        }
      end
    )
  end

  defp search_graph_nodes(conn, fts_query) do
    query_fts(
      conn,
      """
      SELECT node_id, node_type, title, snippet(graph_nodes_fts, 3, '<mark>', '</mark>', '...', 40),
             rank
      FROM graph_nodes_fts
      WHERE graph_nodes_fts MATCH ?1
      ORDER BY rank
      LIMIT 50
      """,
      [fts_query],
      fn [node_id, node_type, title, snippet, rank] ->
        %{
          source: :graph_node,
          title: "[#{node_type}] #{title}",
          snippet: snippet,
          section_number: nil,
          node_id: parse_int(node_id),
          rank: rank
        }
      end
    )
  end

  defp search_documents(conn, fts_query) do
    query_fts(
      conn,
      """
      SELECT doc_id, node_id, filename, snippet(documents_fts, 3, '<mark>', '</mark>', '...', 40),
             rank
      FROM documents_fts
      WHERE documents_fts MATCH ?1
      ORDER BY rank
      LIMIT 50
      """,
      [fts_query],
      fn [_doc_id, node_id, filename, snippet, rank] ->
        %{
          source: :document,
          title: filename,
          snippet: snippet,
          section_number: nil,
          node_id: parse_int(node_id),
          rank: rank
        }
      end
    )
  end

  defp count_matches(conn, table, fts_query) do
    result =
      query_fts(
        conn,
        "SELECT count(*) FROM #{table} WHERE #{table} MATCH ?1",
        [fts_query],
        fn [count] -> count end
      )

    case result do
      [count] when is_integer(count) -> count
      _ -> 0
    end
  end

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

  # -------------------------------------------------------------------
  # Private — helpers
  # -------------------------------------------------------------------

  defp sanitize_fts_query(query) do
    # Escape special FTS5 characters, wrap each token for prefix matching
    query
    |> String.replace(~r/["\(\)\*\:\^]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(fn token -> "\"#{token}\"" end)
    |> Enum.join(" ")
  end

  defp format_analysis_title(filename) do
    filename
    |> String.replace(~r/\.md$/, "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp dedup_results(results) do
    results
    |> Enum.uniq_by(fn r -> {r.source, r.section_number, r.title} end)
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
