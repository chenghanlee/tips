defmodule Tips.Content.Media.ImageParser do
  @moduledoc """
  Classifies an image file by its content with Pillow, in its own OS process.

  `priv/image_parser/classify.py` runs as

      timeout --signal=KILL 5 prlimit --as=1073741824 -- <python> -I classify.py <path>

  `prlimit` exists only on Linux, and macOS does not enforce `RLIMIT_AS`, so
  development on macOS runs without the memory ceiling. The script enforces
  the size ceilings in `docs/design/backend-design.md` ("Image/GIF upload
  integration") from the header before decoding, checks the structure Pillow
  does not, then decodes every frame. Its reasons map to three outcomes:

    * `:too_large` - over the byte, side, frame-pixel, frame-count or total
      pixel ceiling;
    * `:unsupported` - not PNG, JPEG, WebP or GIF by content;
    * `:invalid` - malformed, over the memory ceiling, killed at the deadline,
      or any other parser failure.

  Each parser can use up to 1 GiB, so at most `:size` parsers run at once
  across the application. A caller waits at most `:queue_wait` milliseconds
  for a slot, then gets `{:error, :busy}`. A slot is held until its parser
  process ends, even when the caller exits first. Settings live in `config/config.exs`.
  """

  @behaviour NimblePool

  @max_bytes 10_000_000
  @formats %{"png" => :png, "jpeg" => :jpeg, "webp" => :webp, "gif" => :gif}
  @too_large ~w(bytes_over_limit dimensions_over_limit frame_pixels_over_limit
                frames_over_limit total_pixels_over_limit)

  @type format :: :png | :jpeg | :webp | :gif
  @type image :: %{
          format: format(),
          animated: boolean(),
          width: pos_integer(),
          height: pos_integer(),
          frames: pos_integer()
        }

  @doc false
  def child_spec(_opts) do
    NimblePool.child_spec(worker: {__MODULE__, nil}, pool_size: config(:size), name: __MODULE__)
  end

  @doc "The largest image file, in bytes."
  def max_bytes, do: @max_bytes

  @doc """
  Classifies the file at `path`.

  Options, over the application environment for this module, are
  `:deadline_ms` and `:address_space` (bytes).
  """
  @spec classify(Path.t(), keyword()) ::
          {:ok, image()} | {:error, :too_large | :unsupported | :invalid | :busy}
  def classify(path, opts \\ []) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_bytes -> {:error, :too_large}
      {:ok, %{type: :regular}} -> with_slot(fn -> run(path, opts) end)
      _other -> {:error, :invalid}
    end
  end

  # The slot is held by a task the caller does not own, so a caller that exits or is
  # killed leaves the slot taken until the parser process has ended. The task is
  # bounded by the queue wait and the parser deadline.
  defp with_slot(fun) do
    Tips.Content.Media.ParserTasks
    |> Task.Supervisor.async_nolink(fn -> checkout(fun) end)
    |> Task.await(:infinity)
  end

  defp checkout(fun) do
    NimblePool.checkout!(
      __MODULE__,
      :run,
      fn _from, slot -> {fun.(), slot} end,
      config(:queue_wait)
    )
  catch
    :exit, {:timeout, {NimblePool, :checkout, [__MODULE__]}} -> {:error, :busy}
  end

  defp run(path, opts) do
    opts = Keyword.merge(Application.fetch_env!(:tips, __MODULE__), opts)
    seconds = :erlang.float_to_binary(opts[:deadline_ms] / 1000, decimals: 3)
    script = Application.app_dir(:tips, "priv/image_parser/classify.py")
    parser = [opts[:python], "-I", script, path]

    {output, status} =
      System.cmd(executable!("timeout"), ["--signal=KILL", seconds | ceiling(opts) ++ parser])

    result(status, output)
  end

  defp ceiling(opts) do
    case :os.type() do
      {:unix, :linux} -> [executable!("prlimit"), "--as=#{opts[:address_space]}", "--"]
      _other -> []
    end
  end

  defp executable!(name), do: System.find_executable(name) || raise("#{name} is not installed")

  # One JSON line; exit 137 is the deadline's SIGKILL.
  defp result(0, output) do
    case JSON.decode(String.trim_trailing(output, "\n")) do
      {:ok, %{"verdict" => "accept", "format" => format} = image}
      when is_map_key(@formats, format) ->
        {:ok,
         %{
           format: @formats[format],
           animated: image["frames"] > 1,
           width: image["width"],
           height: image["height"],
           frames: image["frames"]
         }}

      {:ok, %{"verdict" => "reject", "reason" => reason}} when reason in @too_large ->
        {:error, :too_large}

      {:ok, %{"verdict" => "reject", "reason" => "unclassifiable"}} ->
        {:error, :unsupported}

      _other ->
        {:error, :invalid}
    end
  end

  defp result(_status, _output), do: {:error, :invalid}

  defp config(key), do: :tips |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)

  @impl NimblePool
  def init_worker(pool_state), do: {:ok, :slot, pool_state}

  @impl NimblePool
  def handle_checkout(:run, _from, slot, pool_state), do: {:ok, slot, slot, pool_state}
end
