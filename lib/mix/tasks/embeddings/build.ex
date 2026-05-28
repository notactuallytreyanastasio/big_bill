defmodule Mix.Tasks.Embeddings.Build do
  @moduledoc """
  Run the Python embedding pipeline to populate the `search_embeddings`
  Postgres table with pgvector embeddings for bill sections, graph nodes,
  and analysis file chunks.

  Requires:
    - Postgres running with the pgvector extension and `search_embeddings` table
      (run `mix ecto.migrate` first)
    - Python venv active or `sentence-transformers` + `psycopg2-binary` installed
      (see `analytics/requirements.txt`)

  ## Usage

      # Embed all sources
      mix embeddings.build

      # Embed specific source(s) only
      mix embeddings.build --source sections
      mix embeddings.build --source graph_nodes
      mix embeddings.build --source analysis

      # Dry run (generate embeddings, skip Postgres write)
      mix embeddings.build --dry-run
  """
  @shortdoc "Build pgvector embeddings for semantic search"

  use Mix.Task

  @python_bin Application.compile_env(:big_bill, [:semantic_search, :python_bin], "python3")
  @script "analytics/embeddings.py"

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [source: :keep, dry_run: :boolean],
        aliases: [s: :source, n: :dry_run]
      )

    source_args =
      opts
      |> Keyword.get_values(:source)
      |> Enum.flat_map(fn s -> ["--source", s] end)

    dry_run_args =
      if Keyword.get(opts, :dry_run, false), do: ["--dry-run"], else: []

    script = script_path()
    cmd_args = [script] ++ source_args ++ dry_run_args

    Mix.shell().info("Running embedding pipeline...")
    Mix.shell().info("  #{@python_bin} #{Enum.join(cmd_args, " ")}")

    case System.cmd(@python_bin, cmd_args,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Mix.shell().info("Embedding pipeline complete.")

      {_, code} ->
        Mix.raise("Embedding pipeline failed with exit code #{code}.")
    end
  end

  defp script_path do
    project_root = File.cwd!()
    Path.join(project_root, @script)
  end
end
