defmodule EctoLog.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecto_log,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:nimble_parsec, "~> 1.0"},
      {:uuid, "~> 1.0"},
      {:decimal, "~> 1.0 or ~> 2.0"},
      {:briefly, "~> 0.3"},
      {:ex_doc, "~> 0.23", only: :dev, runtime: false}
    ]
  end
end
