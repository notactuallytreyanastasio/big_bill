defmodule Mix.Tasks.Analytics.Run do
  @moduledoc "Run the Python analytics pipeline against the analysis markdown files."
  @shortdoc "Run the Python analytics pipeline"

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Running analytics pipeline...")

    case BigBill.Analytics.run_pipeline() do
      {:ok, output} ->
        Mix.shell().info(output)
        Mix.shell().info("Pipeline complete.")

      {:error, output, code} ->
        Mix.shell().error("Pipeline failed (exit #{code}):\n#{output}")
    end
  end
end
