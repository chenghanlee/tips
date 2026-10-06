# Integrated search gate for #60. See Tips.SearchGate and test/fixtures/search_probe/gate-60.json.
#
#     mix run --no-start scripts/search_gate.exs --validate
#     MIX_ENV=dev mix ecto.reset && TIPS_REAL_PROVIDERS=1 MIX_ENV=dev mix run --no-start scripts/search_gate.exs --real --output PATH
#
# --real calls OpenRouter. It needs TIPS_REAL_PROVIDERS=1, a clean checkout, an empty development database and
# authorization for one run on the issue. It refuses an existing output file.
defmodule SearchGateScript do
  def main(argv) do
    case OptionParser.parse(argv, strict: [validate: :boolean, real: :boolean, output: :string]) do
      {[validate: true], [], []} -> validate()
      {[real: true, output: output], [], []} -> real(output)
      _invalid -> refuse("usage: --validate | --real --output PATH")
    end
  end

  defp validate do
    case Tips.SearchGate.load() do
      {:ok, fixtures} ->
        IO.puts("fixtures match #{fixtures.gate["version"]}: #{inspect(fixtures.hashes)}")
        IO.puts("plan: #{inspect(fixtures.gate["protocol"]["planned_requests"])}")
        0

      {:error, reason} ->
        refuse(inspect(reason))
    end
  end

  defp real(output) do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {dirty, 0} = System.cmd("git", ["status", "--porcelain"])

    cond do
      Mix.env() != :dev -> refuse("run with MIX_ENV=dev")
      System.get_env("TIPS_REAL_PROVIDERS") != "1" -> refuse("set TIPS_REAL_PROVIDERS=1")
      File.exists?(output) -> refuse("#{output} exists")
      dirty != "" -> refuse("the checkout has uncommitted changes")
      true -> run(output, String.trim(sha))
    end
  end

  defp run(output, sha) do
    # Only the gate's own steps may call the provider: no cron scan, no queues.
    oban = Application.fetch_env!(:tips, Oban)
    Application.put_env(:tips, Oban, Keyword.merge(oban, queues: false, plugins: false))
    # Production's level: development's per-query debug logging would add to measured latency.
    Logger.configure(level: :info)
    {:ok, _apps} = Application.ensure_all_started(:tips)
    :real = Tips.ProviderConfig.mode()

    :telemetry.attach(
      :search_gate_finch,
      [:finch, :request, :stop],
      &Tips.SearchGate.handle_finch/4,
      nil
    )

    {:ok, fixtures} = Tips.SearchGate.load()
    {status, report} = Tips.SearchGate.run(fixtures, real: true)

    report =
      Map.merge(report, %{
        code: %{sha: sha, dirty: false},
        versions: versions(),
        command: Enum.join(["mix run --no-start scripts/search_gate.exs" | System.argv()], " ")
      })

    try do
      File.write!(output, JSON.encode!(report))
    rescue
      exception ->
        File.write!(
          output <> ".txt",
          inspect(report, limit: :infinity, printable_limit: :infinity)
        )

        reraise exception, __STACKTRACE__
    end

    IO.puts("#{status}: #{output}")
    if status == :passed, do: 0, else: 1
  end

  defp versions do
    %{rows: [[postgres]]} = Tips.Repo.query!("SELECT version()")

    %{rows: extensions} =
      Tips.Repo.query!("SELECT extname, extversion FROM pg_extension ORDER BY extname")

    %{
      elixir: System.version(),
      otp: System.otp_release(),
      postgres: postgres,
      extensions: Map.new(extensions, fn [name, version] -> {name, version} end),
      deps:
        Map.new(
          ~w(req finch ecto_sql postgrex oban)a,
          &{&1, Application.spec(&1, :vsn) |> to_string()}
        )
    }
  end

  defp refuse(message) do
    IO.puts(:stderr, message)
    2
  end
end

System.halt(SearchGateScript.main(System.argv()))
