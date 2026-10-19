defmodule Tips.MixProject do
  use Mix.Project

  def project do
    [
      app: :tips,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [plt_add_apps: plt_add_apps(Mix.env())]
    ]
  end

  # test/support calls ExUnit and Wallaby, which only the test environment compiles;
  # without them in the PLT, Dialyzer under test reports every such call as unknown.
  defp plt_add_apps(:test), do: [:ex_unit, :wallaby]
  defp plt_add_apps(_), do: []

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Tips.Application, []},
      extra_applications: [:logger, :runtime_tools, :xmerl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:wallaby, "~> 0.31", only: :test, runtime: false},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:salad_ui, "~> 1.0.0"},
      {:mdex, "0.13.5"},
      {:oban, "~> 2.24.1"},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:jose, "~> 1.11"},
      {:nimble_pool, "~> 1.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "image_parser.setup", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.drop": [&guard_database_reset/1, "ecto.drop"],
      "ecto.reset": [&guard_database_reset/1, "ecto.drop", "ecto.setup"],
      test: ["image_parser.setup", "ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "image_parser.setup": &image_parser_setup/1,
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind tips", "esbuild tips"],
      "assets.deploy": [
        "tailwind tips --minify",
        "esbuild tips --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  # Installs Pillow for Tips.Content.Media.ImageParser into _build/image_parser, again
  # whenever priv/image_parser/requirements.txt changes.
  defp image_parser_setup(_args) do
    venv = "_build/image_parser"
    requirements = File.read!("priv/image_parser/requirements.txt")

    if File.read(Path.join(venv, "requirements.txt")) != {:ok, requirements} do
      File.rm_rf!(venv)

      command =
        "python3 -m venv #{venv} && #{venv}/bin/pip install --quiet --disable-pip-version-check " <>
          "--require-hashes " <>
          "--no-deps -r priv/image_parser/requirements.txt"

      if Mix.shell().cmd(command) != 0, do: Mix.raise("Installing the image parser failed")
      File.write!(Path.join(venv, "requirements.txt"), requirements)
    end
  end

  defp guard_database_reset(_args) do
    if Mix.env() == :prod and System.get_env("TIPS_ALLOW_RESET") != "1" do
      Mix.raise("Production database reset is disabled. Set TIPS_ALLOW_RESET=1 to allow it.")
    end
  end
end
