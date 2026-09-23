defmodule Tips.ProviderConfigTest do
  # Each scenario evaluates config/runtime.exs in its own VM, so fixtures and exported
  # variables never touch this VM's environment or application config.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @search ~w(OPENROUTER_API_KEY)
  @image ~w(CLOUDFLARE_ACCOUNT_ID R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_URL)
  @video ~w(CLOUDFLARE_STREAM_API_TOKEN CLOUDFLARE_STREAM_CUSTOMER_CODE CLOUDFLARE_STREAM_SIGNING_KEY)
  @names @search ++ @image ++ @video

  @synthetic %{
    "OPENROUTER_API_KEY" => "synthetic-key",
    "CLOUDFLARE_ACCOUNT_ID" => "synthetic-account",
    "R2_BUCKET" => "synthetic-bucket",
    "R2_ENDPOINT" => "https://synthetic.r2.example.test",
    "R2_ACCESS_KEY_ID" => "synthetic-access-key",
    "R2_SECRET_ACCESS_KEY" => "synthetic secret with spaces",
    "R2_PUBLIC_URL" => "https://images.example.test/path?x=1&y=2",
    "CLOUDFLARE_STREAM_API_TOKEN" => "synthetic-stream-token",
    "CLOUDFLARE_STREAM_CUSTOMER_CODE" => "synthetic-customer",
    "CLOUDFLARE_STREAM_SIGNING_KEY" => "LS0tLS1CRUdJTi+synthetic/key=="
  }

  @fetch_all """
  for name <- #{inspect(@names)}, into: %{} do
    try do
      {name, {:ok, Tips.ProviderConfig.fetch!(name)}}
    rescue
      error -> {name, {:error, error.__struct__, Exception.message(error)}}
    end
  end
  """

  test "dev runtime config evaluates with absent or empty .env; search, image and video lookups name the missing variable",
       %{tmp_dir: tmp_dir} do
    for dotenv <- [nil, ""] do
      results = run!(tmp_dir, :dev, @fetch_all, dotenv: dotenv)

      for name <- @names do
        assert {:error, RuntimeError, message} = results[name]
        assert message =~ name
      end
    end
  end

  test "all ten names load from .env in dev and test, including a file with a UTF-8 BOM",
       %{tmp_dir: tmp_dir} do
    dotenv = """
    # Provider settings
    OPENROUTER_API_KEY=synthetic-key
    export CLOUDFLARE_ACCOUNT_ID=synthetic-account
    R2_BUCKET=synthetic-bucket   # trailing comment
    R2_ENDPOINT=https://synthetic.r2.example.test
    R2_ACCESS_KEY_ID=synthetic-access-key
    R2_SECRET_ACCESS_KEY='synthetic secret with spaces'
    R2_PUBLIC_URL="https://images.example.test/path?x=1&y=2"
    CLOUDFLARE_STREAM_API_TOKEN=stale-value
    CLOUDFLARE_STREAM_API_TOKEN=synthetic-stream-token
    CLOUDFLARE_STREAM_CUSTOMER_CODE=synthetic-customer
    CLOUDFLARE_STREAM_SIGNING_KEY="LS0tLS1CRUdJTi+synthetic/key=="
    SECRET_KEY_BASE=$(mix phx.gen.secret)
    not an assignment
    """

    expected = Map.new(@synthetic, fn {name, value} -> {name, {:ok, value}} end)

    for env <- [:dev, :test] do
      assert run!(tmp_dir, env, @fetch_all, dotenv: dotenv) == expected
    end

    assert %{"R2_BUCKET" => {:ok, "bom-bucket"}} =
             run!(tmp_dir, :dev, @fetch_all, dotenv: "\uFEFFR2_BUCKET=bom-bucket\n")
  end

  test "exported environment wins over .env", %{tmp_dir: tmp_dir} do
    results =
      run!(tmp_dir, :dev, @fetch_all,
        dotenv: "R2_BUCKET=from-dotenv\nR2_ENDPOINT=from-dotenv\n",
        exported: %{"R2_BUCKET" => "from-shell"}
      )

    assert results["R2_BUCKET"] == {:ok, "from-shell"}
    assert results["R2_ENDPOINT"] == {:ok, "from-dotenv"}
  end

  test "missing or blank values fail by name only; unrelated values stay usable",
       %{tmp_dir: tmp_dir} do
    {output, 0} =
      run(tmp_dir, :test, @fetch_all,
        dotenv: "OPENROUTER_API_KEY=sentinel-openrouter-value\nR2_BUCKET='   '\n",
        exported: %{"CLOUDFLARE_STREAM_API_TOKEN" => ""}
      )

    results = decode(output)
    assert results["OPENROUTER_API_KEY"] == {:ok, "sentinel-openrouter-value"}

    for name <- ~w(R2_BUCKET CLOUDFLARE_STREAM_API_TOKEN CLOUDFLARE_STREAM_SIGNING_KEY) do
      assert {:error, RuntimeError, message} = results[name]
      assert message =~ name
      refute message =~ "sentinel"
    end

    {output, 0} =
      run(tmp_dir, :test, ~s|Tips.ProviderConfig.fetch!("SENTINEL_UNKNOWN_NAME")|,
        dotenv: "OPENROUTER_API_KEY=sentinel-openrouter-value\n",
        catch: true
      )

    assert {:error, ArgumentError, message} = decode(output)
    refute message =~ "SENTINEL"
    refute output =~ "sentinel"
  end

  test "test uses stub mode even with credentials; only TIPS_REAL_PROVIDERS=1 selects real",
       %{tmp_dir: tmp_dir} do
    dotenv = Enum.map_join(@synthetic, "\n", fn {name, value} -> "#{name}='#{value}'" end)
    mode = "Tips.ProviderConfig.mode()"

    assert run!(tmp_dir, :test, mode, dotenv: dotenv) == :stub

    assert run!(tmp_dir, :test, mode, dotenv: dotenv, exported: @synthetic) == :stub

    assert run!(tmp_dir, :test, mode, exported: %{"TIPS_REAL_PROVIDERS" => "true"}) == :stub

    assert run!(tmp_dir, :test, mode, dotenv: dotenv, exported: %{"TIPS_REAL_PROVIDERS" => "1"}) ==
             :real

    assert run!(tmp_dir, :dev, mode) == :real
  end

  test "malformed assignments and an unreadable .env fail with secret-free diagnostics",
       %{tmp_dir: tmp_dir} do
    for line <- [
          ~s|R2_SECRET_ACCESS_KEY="sentinel-unterminated|,
          ~s|R2_SECRET_ACCESS_KEY='sentinel-unterminated|,
          ~s|R2_SECRET_ACCESS_KEY=sentinel words|,
          ~s|R2_SECRET_ACCESS_KEY=$(cat sentinel-file)|,
          ~s|R2_SECRET_ACCESS_KEY="sentinel-$HOME"|,
          ~s|R2_SECRET_ACCESS_KEY = sentinel-spaced|,
          ~s|R2_SECRET_ACCESS_KEY="sentinel-value"trailing|
        ] do
      {output, status} = run(tmp_dir, :dev, "nil", dotenv: "# header\n#{line}\n")

      assert status != 0, line
      assert output =~ ".env:2"
      assert output =~ "R2_SECRET_ACCESS_KEY"
      refute output =~ "sentinel", line
    end

    {output, status} = run(tmp_dir, :dev, "nil", dotenv: :directory)
    assert status != 0
    assert output =~ ".env: cannot read"
  end

  test "production ignores local .env", %{tmp_dir: tmp_dir} do
    dotenv = Enum.map_join(@synthetic, "\n", fn {name, value} -> "#{name}='#{value}'" end)

    exported = %{
      "DATABASE_URL" => "ecto://user:pass@localhost/tips_prod",
      "SECRET_KEY_BASE" => String.duplicate("s", 64)
    }

    assert run!(tmp_dir, :prod, "Application.get_env(:tips, Tips.ProviderConfig)",
             dotenv: dotenv <> "\nR2_BUCKET=\"unterminated\n",
             exported: exported
           ) == nil
  end

  @tag :real_provider
  test "real-provider tests run only after an explicit opt-in" do
    assert Tips.ProviderConfig.mode() == :real
  end

  defp run!(tmp_dir, env, code, opts \\ []) do
    {output, 0} = run(tmp_dir, env, code, opts)
    decode(output)
  end

  # Copies config/runtime.exs beside the fixture's .env, then evaluates it and `code` in a
  # fresh VM with every provider variable unset unless the scenario exports it.
  defp run(tmp_dir, env, code, opts) do
    config_dir = Path.join(tmp_dir, "config")
    dotenv_path = Path.join(tmp_dir, ".env")
    File.mkdir_p!(config_dir)

    File.cp!(
      Path.expand("../../config/runtime.exs", __DIR__),
      Path.join(config_dir, "runtime.exs")
    )

    File.rm_rf!(dotenv_path)

    case opts[:dotenv] do
      nil -> :ok
      :directory -> File.mkdir!(dotenv_path)
      contents -> File.write!(dotenv_path, contents)
    end

    exported =
      (@names ++ ["TIPS_REAL_PROVIDERS"])
      |> Map.new(&{&1, nil})
      |> Map.merge(opts[:exported] || %{})

    code =
      if opts[:catch] do
        "try do #{code} rescue error -> {:error, error.__struct__, Exception.message(error)} end"
      else
        code
      end

    script = """
    Application.put_all_env(Config.Reader.read!("config/runtime.exs", env: #{inspect(env)}))
    result = (#{code})
    IO.puts("RESULT:" <> Base.encode64(:erlang.term_to_binary(result)))
    """

    System.cmd(
      System.find_executable("elixir"),
      ["-pa", Application.app_dir(:tips, "ebin"), "-e", script],
      cd: tmp_dir,
      env: Enum.to_list(exported),
      stderr_to_stdout: true
    )
  end

  defp decode(output) do
    [_, encoded] = Regex.run(~r/^RESULT:(\S+)$/m, output)
    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end
end
