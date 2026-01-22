defmodule MiniMe.Transform.Pipeline do
  @moduledoc """
  Transforms Claude Code output for web display.

  Handles:
  - ANSI code stripping
  - Verbose output collapsing
  - Code block formatting for web
  """

  @ansi_regex ~r/\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?\x07/

  @doc """
  Strip ANSI escape codes from text.
  """
  def strip_ansi(text) do
    Regex.replace(@ansi_regex, text, "")
  end

  @doc """
  Collapse verbose command output into summaries.
  """
  def collapse_verbose_output(text) do
    text
    |> collapse_npm_output()
    |> collapse_build_output()
    |> collapse_test_output()
  end

  @doc """
  Format text for web display.
  Handles basic cleanup without SMS-specific link conversion.
  """
  def format_for_web(text) do
    text
    |> strip_ansi()
    |> collapse_verbose_output()
    |> String.trim()
  end

  @doc """
  Transform a chunk of text through the full pipeline.
  """
  def transform(text) do
    format_for_web(text)
  end

  # Private Functions

  defp collapse_npm_output(text) do
    # Detect npm install output and summarize
    cond do
      String.contains?(text, "added") && String.contains?(text, "packages") ->
        # Extract summary line
        case Regex.run(~r/added (\d+) packages.*in (\d+\.?\d*)s/, text) do
          [_, count, time] ->
            "Installed #{count} packages in #{time}s"

          nil ->
            text
        end

      String.contains?(text, "up to date") ->
        "Dependencies up to date"

      true ->
        text
    end
  end

  defp collapse_build_output(text) do
    if build_output?(text) do
      extract_build_summary(text)
    else
      text
    end
  end

  defp build_output?(text) do
    String.contains?(text, ["webpack", "vite", "esbuild"]) &&
      String.contains?(text, ["Built", "built", "Done", "done"])
  end

  defp extract_build_summary(text) do
    summary =
      text
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.contains?(line, ["Built", "built", "Done", "done", "Error", "error", "Warning"])
      end)
      |> Enum.join("\n")

    if summary == "", do: "Build completed", else: summary
  end

  defp collapse_test_output(text) do
    if test_output?(text) do
      extract_test_summary(text)
    else
      text
    end
  end

  defp test_output?(text) do
    String.contains?(text, ["PASS", "FAIL", "passed", "failed"]) &&
      String.contains?(text, ["test", "spec", "Test"])
  end

  defp extract_test_summary(text) do
    summary =
      text
      |> String.split("\n")
      |> Enum.filter(fn line ->
        Regex.match?(~r/(PASS|FAIL|\d+ (passed|failed|skipped)|Tests?:)/, line)
      end)
      |> Enum.join("\n")

    if summary == "", do: text, else: summary
  end
end
