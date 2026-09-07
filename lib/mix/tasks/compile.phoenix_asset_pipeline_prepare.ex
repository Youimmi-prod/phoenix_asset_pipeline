defmodule Mix.Tasks.Compile.PhoenixAssetPipelinePrepare do
  @shortdoc "Prepares fixed module-scope class mappings"
  @moduledoc false
  use Mix.Task.Compiler

  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.HTML.ModuleClasses

  @mode if(Config.precompiled_manifest?(),
          do: :deterministic,
          else: :stable
        )

  @impl true
  def run(_) do
    case ModuleClasses.prepare!(@mode) do
      :current -> {:noop, []}
      :updated -> {:ok, []}
    end
  end
end
