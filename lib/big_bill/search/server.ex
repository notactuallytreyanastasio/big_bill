defmodule BigBill.Search.Server do
  @moduledoc """
  GenServer that holds an open SQLite connection for the FTS5 search index.

  Started under the application supervisor so the connection stays open
  for the lifetime of the application. All search queries flow through
  this process to avoid repeatedly opening/closing the database.
  """

  use GenServer

  alias BigBill.Search

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  @doc "Start the search server and link it to the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Rebuild the full-text search index from scratch."
  @spec rebuild() :: :ok
  def rebuild do
    GenServer.call(__MODULE__, :rebuild, :infinity)
  end

  @doc "Execute a search query against the given facet (or :all)."
  @spec search(String.t(), Search.source() | :all) :: [Search.result()]
  def search(query, facet) do
    GenServer.call(__MODULE__, {:search, query, facet})
  end

  @doc "Return result counts per facet for the given query."
  @spec facet_counts(String.t()) :: %{Search.source() => non_neg_integer()}
  def facet_counts(query) do
    GenServer.call(__MODULE__, {:facet_counts, query})
  end

  @doc """
  Execute a function with the raw SQLite connection.

  The function receives the open `Exqlite.Sqlite3` connection reference
  and may run arbitrary queries. Used by `BigBill.Search.Advanced` for
  scoped search and find-related queries.
  """
  @spec call_with_conn((reference() -> term())) :: term()
  def call_with_conn(fun) when is_function(fun, 1) do
    GenServer.call(__MODULE__, {:call_with_conn, fun})
  end

  # -------------------------------------------------------------------
  # Server callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    db_path = Search.db_path()
    needs_build = not Search.index_exists?()
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    if needs_build do
      Search.populate(conn)
    end

    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call(:rebuild, _from, %{conn: conn} = state) do
    Search.populate(conn)
    {:reply, :ok, state}
  end

  def handle_call({:search, query, facet}, _from, %{conn: conn} = state) do
    results = Search.execute_search(conn, query, facet)
    {:reply, results, state}
  end

  def handle_call({:facet_counts, query}, _from, %{conn: conn} = state) do
    counts = Search.execute_facet_counts(conn, query)
    {:reply, counts, state}
  end

  def handle_call({:call_with_conn, fun}, _from, %{conn: conn} = state) do
    result = fun.(conn)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    Exqlite.Sqlite3.close(conn)
    :ok
  end
end
