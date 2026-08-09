defmodule Mix.Exec.Utils do
  def ensure_app_started! do
    Mix.Task.run("app.start", [])
  end
end
