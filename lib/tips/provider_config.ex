defmodule Tips.ProviderConfig do
  @moduledoc """
  Provider settings for development and test.

  `config/runtime.exs` loads the ten fixed names from the checkout's `.env` and the
  exported environment, with exported values winning. Callers request a value when
  they need it, so a missing setting only fails the feature that uses it. Errors name
  the variable and never include a value.
  """

  @names ~w(
    OPENROUTER_API_KEY
    CLOUDFLARE_ACCOUNT_ID
    R2_BUCKET
    R2_ENDPOINT
    R2_ACCESS_KEY_ID
    R2_SECRET_ACCESS_KEY
    R2_PUBLIC_URL
    CLOUDFLARE_STREAM_API_TOKEN
    CLOUDFLARE_STREAM_CUSTOMER_CODE
    CLOUDFLARE_STREAM_SIGNING_KEY
  )

  # A value is unquoted from a shell-safe character set, single-quoted, or double-quoted
  # without `$`, backticks or backslashes, so the shell and this parser read the same value.
  @assignment ~r/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)(.*)$/
  @value ~r/^=(?:'([^']*)'|"([^"$`\\]*)"|([A-Za-z0-9_.\/:@+=,%-]*))(?:\s+#.*)?\s*$/

  @doc """
  Returns the non-blank value of a provider variable.

  Raises naming the variable when it is missing or blank.
  """
  def fetch!(name) when name in @names do
    value =
      :tips
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:values, %{})
      |> Map.get(name, "")

    if String.trim(value) == "" do
      raise "#{name} is missing or blank. Set it in .env, then re-source .env or " <>
              "unset an overriding export; an exported value, even an empty one, wins."
    end

    value
  end

  def fetch!(_name), do: raise(ArgumentError, "unknown provider configuration name")

  @doc """
  Returns `:real` or `:stub`.

  Test runs use `:stub` unless `TIPS_REAL_PROVIDERS=1`; development uses `:real`.
  """
  def mode, do: :tips |> Application.get_env(__MODULE__, []) |> Keyword.get(:mode, :real)

  @doc """
  Reads provider values from the `.env` file at `path` and the exported `env` map.

  Exported values win. A missing file is normal. Other names in the file are ignored;
  a malformed provider line raises with its line number and name, never its value.
  """
  def load(path, env) do
    path |> read_dotenv() |> Map.merge(Map.take(env, @names))
  end

  defp read_dotenv(path) do
    case File.read(path) do
      {:ok, contents} -> parse(path, String.trim_leading(contents, "\uFEFF"))
      {:error, :enoent} -> %{}
      {:error, reason} -> raise "#{path}: cannot read (#{:file.format_error(reason)})"
    end
  end

  defp parse(path, contents) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {line, number}, values ->
      case Regex.run(@assignment, line, capture: :all_but_first) do
        [name, rest] when name in @names ->
          Map.put(values, name, value!(rest, path, number, name))

        _other ->
          values
      end
    end)
  end

  defp value!(rest, path, number, name) do
    case Regex.run(@value, rest, capture: :all_but_first) do
      # Only one alternative matches; the others capture "".
      [_ | _] = parts ->
        Enum.join(parts)

      nil ->
        raise """
        #{path}:#{number}: invalid value for #{name}. \
        Use NAME=value, NAME='value' or NAME="value" without $, ` or \\ in double quotes.\
        """
    end
  end
end
