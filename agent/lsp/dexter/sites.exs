# DX outgoing-calls helper: lists the call sites of the function at a line.
# It only parses with Code.string_to_quoted; nothing is read, evaluated or compiled.
# Needs Elixir 1.18+ for the built-in JSON module.
#
#   stdin:  {"source": "...", "line": 12}
#   stdout: {"caller": {"module": ..., "name": ..., "arity": ...},
#            "clauses": [{"line": ..., "end_line": ...}],
#            "sites": [{"name": ..., "range": {"start": {"line": ..., "character": ...},
#                                              "end": {"line": ..., "character": ...}}}]}
#           and exit 0, or a message on stderr and exit 1.
#
# line is 1-based and may fall on any line of a def/defp/defmacro/defmacrop
# clause, from its head to its closing end. Every clause with the same lexical
# module, name and head arity contributes; a bodiless default head adds no
# sites. Two different functions on the selected line are an error. Clause lines
# are 1-based. Site ranges are LSP ranges: zero-based lines, UTF-16 characters,
# covering the called name. Sites name the call only: there is no alias, import
# or target resolution.
#
# Heads, guards and default arguments are not searched. Not sites: operators,
# special forms, if/unless, calls without a static name (fun.(), var.fun()) and
# map field access. quote and sigil bodies are skipped.
defmodule DxSites do
  @moduledoc false

  @def_kinds [:def, :defp, :defmacro, :defmacrop]
  @controls [:if, :unless]

  def main do
    with {:ok, text} <- read_stdin(),
         {:ok, input} <- decode(text),
         {:ok, source, line} <- validate(input),
         {:ok, ast} <- parse(source),
         {:ok, caller, clauses} <- select(ast, line) do
      IO.write(JSON.encode!(result(caller, clauses, source)))
    else
      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      text when is_binary(text) -> {:ok, text}
      other -> {:error, "cannot read stdin: #{inspect(other)}"}
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, input} -> {:ok, input}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end

  defp validate(%{"source" => source, "line" => line})
       when is_binary(source) and is_integer(line) and line > 0,
       do: {:ok, source, line}

  defp validate(_input), do: {:error, "expected {\"source\": string, \"line\": positive integer}"}

  defp parse(source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true, emit_warnings: false) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {location, message, token}} ->
        {:error, "line #{location[:line]}: #{text(message)}#{token}"}
    end
  end

  defp text({prefix, suffix}), do: prefix <> suffix
  defp text(message), do: message

  defp select(ast, line) do
    clauses = ast |> clauses(nil, []) |> Enum.reverse()

    case clauses
         |> Enum.filter(&(line in &1.line..&1.end_line//1))
         |> Enum.map(& &1.key)
         |> Enum.uniq() do
      [key] -> {:ok, key, Enum.filter(clauses, &(&1.key == key))}
      [] -> {:error, "no def clause contains line #{line}"}
      _keys -> {:error, "line #{line} is inside more than one function"}
    end
  end

  defp result({module, name, arity}, clauses, source) do
    lines = source |> String.split("\n") |> List.to_tuple()

    %{
      caller: %{module: module, name: name, arity: arity},
      clauses: Enum.map(clauses, &Map.take(&1, [:line, :end_line])),
      sites:
        clauses
        |> Enum.flat_map(&sites(&1.body, []))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&lsp_site(&1, lines))
    }
  end

  # Def clauses written directly in a module body, newest first.
  defp clauses({:defmodule, _meta, [name, [{:do, body}]]}, outer, acc),
    do: clauses(body, module_name(name, outer), acc)

  defp clauses({:__block__, _meta, exprs}, module, acc),
    do: Enum.reduce(exprs, acc, &clauses(&1, module, &2))

  defp clauses({kind, meta, [head | body]} = node, module, acc)
       when kind in @def_kinds and is_binary(module) and length(body) <= 1 do
    case signature(head) do
      {name, arity} ->
        clause = %{
          key: {module, name, arity},
          line: meta[:line],
          end_line: max_line(node),
          body: body
        }

        [clause | acc]

      nil ->
        acc
    end
  end

  defp clauses(_expr, _module, acc), do: acc

  # Nested defmodule names are prefixed with the enclosing module, as in Elixir.
  defp module_name({:__aliases__, _meta, [:"Elixir" | parts]}, _outer),
    do: module_name({:__aliases__, [], parts}, nil)

  defp module_name({:__aliases__, _meta, parts}, outer) do
    if Enum.all?(parts, &is_atom/1),
      do: nest(outer, Enum.map_join(parts, ".", &Atom.to_string/1)),
      else: :dynamic
  end

  defp module_name(_name, _outer), do: :dynamic

  defp nest(nil, name), do: name
  defp nest(:dynamic, _name), do: :dynamic
  defp nest(outer, name), do: outer <> "." <> name

  defp signature({:when, _meta, [call | _guards]}), do: signature(call)

  defp signature({name, _meta, args})
       when is_atom(name) and name not in [:unquote, :unquote_splicing] and
              (is_list(args) or is_atom(args)),
       do: {name, length(List.wrap(args))}

  defp signature(_head), do: nil

  # Largest line in the clause's own metadata or any descendant.
  defp max_line(node) do
    {_node, max} =
      Macro.prewalk(node, 0, fn
        {_, meta, _} = child, max when is_list(meta) ->
          {child, Enum.max([max | meta_lines(meta)])}

        child, max ->
          {child, max}
      end)

    max
  end

  defp meta_lines(meta) do
    nested = for key <- [:closing, :end, :end_of_expression], pos = meta[key], do: pos[:line]
    Enum.filter([meta[:line] | nested], &is_integer/1)
  end

  # Call-name positions in a clause body. Operators, special forms and controls
  # are not sites, but their arguments are searched.
  defp sites({:quote, _meta, _args}, acc), do: acc

  defp sites({:&, _meta, [{:/, _, [{name, meta, context}, arity]}]}, acc)
       when is_atom(name) and is_atom(context) and is_integer(arity),
       do: [site(name, meta) | acc]

  defp sites({{:., _, [fun]}, _meta, args}, acc), do: sites([fun | args], acc)

  # "#{...}" wraps its expression in a parser-generated Kernel.to_string call
  # marked from_interpolation; only its argument is source.
  defp sites({{:., _, [receiver, name]}, meta, args}, acc)
       when is_atom(name) and is_list(args) do
    acc =
      if static_module?(receiver) and meta[:from_interpolation] != true,
        do: [site(name, meta) | acc],
        else: acc

    sites([receiver | args], acc)
  end

  defp sites({name, meta, args}, acc) when is_atom(name) and is_list(args) do
    cond do
      String.starts_with?(Atom.to_string(name), "sigil_") -> acc
      call_name?(name, length(args)) -> sites(args, [site(name, meta) | acc])
      true -> sites(args, acc)
    end
  end

  defp sites({form, _meta, args}, acc) when is_list(args), do: sites([form | args], acc)
  defp sites({left, right}, acc), do: sites(right, sites(left, acc))
  defp sites(list, acc) when is_list(list), do: Enum.reduce(list, acc, &sites/2)
  defp sites(_literal_or_variable, acc), do: acc

  defp site(name, meta), do: {meta[:line], meta[:column], Atom.to_string(name)}

  defp static_module?({:__aliases__, _meta, _parts}), do: true
  defp static_module?({:__MODULE__, _meta, context}) when is_atom(context), do: true
  defp static_module?(module), do: is_atom(module)

  defp call_name?(name, arity),
    do:
      not (Macro.operator?(name, arity) or Macro.special_form?(name, arity) or name in @controls)

  # Parser columns count graphemes from 1; LSP characters count UTF-16 units from 0.
  defp lsp_site({line, column, name}, lines) do
    start =
      lines |> elem(line - 1) |> String.graphemes() |> Enum.take(column - 1) |> utf16_length()

    position = &%{line: line - 1, character: &1}
    %{name: name, range: %{start: position.(start), end: position.(start + utf16_length(name))}}
  end

  defp utf16_length(text),
    do:
      text
      |> IO.chardata_to_string()
      |> :unicode.characters_to_binary(:utf8, :utf16)
      |> byte_size()
      |> div(2)
end

DxSites.main()
