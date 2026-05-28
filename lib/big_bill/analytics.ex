defmodule BigBill.Analytics do
  @moduledoc """
  Thin wrapper around the Python analytics pipeline.

  Python writes DuckDB + JSON reports via System.cmd.
  Elixir reads the JSON reports and can query DuckDB read-only via duckdbex.
  """

  @type report_data :: %{String.t() => term()}

  @analytics_dir Path.join(File.cwd!(), "analytics")
  @output_dir Path.join(@analytics_dir, "output")
  @venv_python Path.join(@analytics_dir, ".venv/bin/python3")

  @doc """
  Run the full Python analytics pipeline.
  """
  @spec run_pipeline(keyword()) :: {:ok, String.t()} | {:error, String.t(), integer()}
  def run_pipeline(opts \\ []) do
    args = ["analytics/pipeline.py"]
    args = if opts[:parse_only], do: args ++ ["--parse-only"], else: args
    args = if opts[:report], do: args ++ ["--report", opts[:report]], else: args

    python = if File.exists?(@venv_python), do: @venv_python, else: "python3"

    case System.cmd(python, args, cd: File.cwd!(), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, output, code}
    end
  end

  @doc """
  Load a named report from the output directory.
  """
  @spec load_report(String.t()) :: {:ok, report_data()} | {:error, term()}
  def load_report(name) do
    path = Path.join(@output_dir, "#{name}.json")

    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      {:ok, data}
    end
  end

  @doc """
  List available reports.
  """
  @spec list_reports() :: [String.t()]
  def list_reports do
    case File.ls(@output_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.trim_trailing(&1, ".json"))
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc """
  Check if the pipeline has been run (output directory has reports).
  """
  @spec pipeline_run?() :: boolean()
  def pipeline_run? do
    list_reports() != []
  end
end
