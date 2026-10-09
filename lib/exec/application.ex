defmodule Exec.Application do
  @moduledoc false

  # Owns the supervisor that running programs are started under. `:erlexec` is
  # an ordinary dependency that starts, configures and supervises itself, and
  # this module leaves it exactly as it is.

  use Application

  @impl Application
  def start(_type, _args) do
    children = [Exec.ProgramSupervisor]
    Supervisor.start_link(children, strategy: :one_for_one, name: Exec.Supervisor)
  end
end
