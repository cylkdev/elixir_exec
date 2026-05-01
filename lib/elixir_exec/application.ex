defmodule ElixirExec.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {ElixirExec.StreamSupervisor, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixirExec.Supervisor)
  end
end
