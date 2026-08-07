defmodule Exec.ProgramSupervisor do
  @moduledoc false

  # Every running program hangs off here, one child per program. Children are
  # `:temporary` -- a program that ends has ended, and restarting it would run
  # the command a second time -- so this supervisor exists to own them and take
  # them down with the VM, not to bring them back.

  use DynamicSupervisor

  alias Exec.Program

  # :temporary: a restarted worker would re-run the command, and its program is
  # already gone.
  def start_program(command, owner, opts) do
    DynamicSupervisor.start_child(__MODULE__, %{
      id: Program,
      start: {Program, :start_link, [command, owner, opts]},
      restart: :temporary
    })
  end

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
