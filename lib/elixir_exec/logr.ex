defmodule ElixirExec.Logr do
  @moduledoc """
  Logging utility module for ElixirExec.

  Provides consistent logging across the application with structured formatting.

  ## Usage

  To use this module in your own modules, simply alias it and set a prefix:

  ```elixir
  defmodule MyApp.MyModule do
    alias ElixirExec.Logr

    # <Set the prefix to the module name as a string>
    @logger_prefix "MyApp.MyModule"

    def log_debug_string do
      Logr.debug(@logger_prefix, "Something happened")
    end
  end
  ```
  """
  require Logger

  @type t_error :: %{code: atom() | String.t(), message: String.t(), details: nil | map()}

  @doc """
  Logs a debug message with the given prefix and message.

  ## Examples

      iex> ElixirExec.Logr.debug("MyModule", "Something happened")
      :ok

      iex> ElixirExec.Logr.debug("MyModule", %{code: :file_not_found, message: "File not found", details: %{path: "/tmp/file.txt"}})
      :ok
  """
  @spec debug(prefix :: binary(), message :: binary() | t_error()) :: :ok
  def debug(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.debug()
  end

  @doc """
  Logs an info message with the given prefix and message.

  ## Examples

      iex> ElixirExec.Logr.info("MyModule", "Something happened")
      :ok

      iex> ElixirExec.Logr.info("MyModule", %{code: :file_not_found, message: "File not found", details: %{path: "/tmp/file.txt"}})
      :ok
  """
  @spec info(prefix :: binary(), message :: binary() | t_error()) :: :ok
  def info(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.info()
  end

  @doc """
  Logs a warning message with the given prefix and message.

  ## Examples

      iex> ElixirExec.Logr.warning("MyModule", "Something happened")
      :ok

      iex> ElixirExec.Logr.warning("MyModule", %{code: :file_not_found, message: "File not found", details: %{path: "/tmp/file.txt"}})
      :ok
  """
  @spec warning(prefix :: binary(), message :: binary() | t_error()) :: :ok
  def warning(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.warning()
  end

  @doc """
  Logs an error message with the given prefix and message.

  ## Examples

      iex> ElixirExec.Logr.error("MyModule", "Something happened")
      :ok

      iex> ElixirExec.Logr.error("MyModule", %{code: :file_not_found, message: "File not found", details: %{path: "/tmp/file.txt"}})
      :ok
  """
  @spec error(prefix :: binary(), message :: binary() | t_error()) :: :ok
  def error(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.error()
  end

  defp format_message(prefix, %{code: code, message: message, details: details}) do
    "[#{prefix}] #{code}: #{message}" <>
      "\n\n#{inspect(details, pretty: true)}"
  end

  defp format_message(prefix, message) do
    "[#{prefix}] #{message}"
  end
end
