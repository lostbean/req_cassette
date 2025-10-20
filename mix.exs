defmodule ReqCassette.MixProject do
  use Mix.Project

  def project do
    [
      app: :req_cassette,
      version: "0.3.2",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description: "VCR-style record-and-replay library for Req HTTP client",
      package: package(),

      # Docs
      name: "ReqCassette",
      source_url: "https://github.com/lostbean/req_cassette",
      homepage_url: "https://github.com/lostbean/req_cassette",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5.15"},
      {:plug, "~> 1.18"},
      {:jason, "~> 1.4"},
      {:req_llm, "~> 1.0.0-rc.7", only: [:dev, :test], runtime: false},
      {:bypass, "~> 2.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, ci: :test]]
  end

  # Aliases for common tasks
  defp aliases do
    [
      precommit: [
        "format",
        "credo --strict",
        "test"
      ],
      ci: [
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/lostbean/req_cassette"
      },
      maintainers: ["Edgar Gomes"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "ReqCassette",
      extras: [
        "docs/guides/templating.md": [title: "Templating Guide"],
        "docs/MIGRATION_V0.2_TO_V0.3.md": [title: "Migration Guide (v0.2 → v0.3)"],
        "docs/MIGRATION_V0.1_TO_V0.2.md": [title: "Migration Guide (v0.1 → v0.2)"],
        "docs/REQ_LLM_INTEGRATION.md": [title: "ReqLLM Integration Guide"],
        "docs/SENSITIVE_DATA_FILTERING.md": [title: "Sensitive Data Filtering Guide"]
      ],
      source_ref: "v0.3.0",
      formatters: ["html"],
      groups_for_extras: [
        Guides: ~r/docs\/guides/,
        "Integration Guides": ~r/docs\/(REQ_LLM|SENSITIVE)/,
        "Migration Guides": ~r/docs\/MIGRATION/
      ],
      groups_for_modules: [
        Core: [
          ReqCassette,
          ReqCassette.Plug
        ],
        "Cassette Format": [
          ReqCassette.Cassette,
          ReqCassette.BodyType
        ],
        Filtering: [
          ReqCassette.Filter
        ]
      ]
    ]
  end
end
