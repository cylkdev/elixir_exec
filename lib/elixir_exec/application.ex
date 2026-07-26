defmodule ElixirExec.Application do
  @moduledoc false

  # Owns the supervisor that running programs are started under. It does not
  # start, configure or wrap `:erlexec` -- that is an ordinary dependency which
  # supervises itself.

  use Application

  @impl Application
  def start(_type, _args) do
    children = [ElixirExec.ConnectionSupervisor]
    Supervisor.start_link(children, strategy: :one_for_one, name: ElixirExec.Supervisor)
  end
end
