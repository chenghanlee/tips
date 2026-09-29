# DX incoming-calls helper: finds the source owner of each Dexter reference line.
# It only parses with Code.string_to_quoted; nothing is evaluated or compiled.
# Needs Elixir 1.18+ for the built-in JSON module.
#
#   stdin:  {"target": {"module": "...", "function": "admit"},
#            "files": [{"path": "...", "source": "...", "lines": [5, 9]}]}
#   stdout: {"sites": [...], "unavailable": [...]} and exit 0, or
#           {"error": {"reason": "invalid_input", "detail": "..."}} and exit 1.
#
# Target identity comes from Dexter's reference lines. There is no alias or
# import resolver, so target.module is not read; the function name only picks
# candidate calls. Lines are 1-based. Owner line/end_line are source bounds for
# navigation, not LSP ranges. Repeated input lines are answered once.
# Calls in default values are owned by the lexical clause, with
# arity_ambiguous true; Elixir runs them in generated lower-arity clauses.
defmodule DxOwners do
  @moduledoc false

  @def_kinds [:def, :defp, :defmacro, :defmacrop]
  @block_kinds [:test, :setup, :setup_all]
  @spec_attrs [:spec, :type, :typep, :opaque, :callback, :macrocallback]

  def main do
    with {:ok, text} <- read_stdin(),
         {:ok, input} <- JSON.decode(text),
         {:ok, fun, files} <- validate(input) do
      {sites, unavailable} =
        files
        |> Enum.flat_map(&file_entries(&1, fun))
        |> Enum.split_with(&match?({:site, _}, &1))

      IO.write(JSON.encode!(%{sites: untag(sites), unavailable: untag(unavailable)}))
    else
      {:error, reason} ->
        IO.write(JSON.encode!(%{error: %{reason: "invalid_input", detail: detail(reason)}}))
        System.halt(1)
    end
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      text when is_binary(text) -> {:ok, text}
      other -> {:error, {:stdin, other}}
    end
  end

  defp validate(%{"target" => %{"function" => fun}, "files" => files})
       when is_binary(fun) and fun != "" and is_list(files) do
    if Enum.all?(files, &valid_file?/1) and Enum.uniq_by(files, & &1["path"]) == files do
      {:ok, String.to_atom(fun), files}
    else
      {:error, "each file needs a unique path, a source and positive integer lines"}
    end
  end

  defp validate(_input), do: {:error, "expected target.function and a files list"}

  defp valid_file?(%{"path" => path, "source" => source, "lines" => lines})
       when is_binary(path) and is_binary(source) and is_list(lines),
       do: Enum.all?(lines, &(is_integer(&1) and &1 > 0))

  defp valid_file?(_file), do: false

  defp detail(reason) when is_binary(reason), do: reason
  defp detail(reason), do: inspect(reason)

  defp untag(entries), do: Enum.map(entries, &elem(&1, 1))

  defp file_entries(%{"path" => path, "source" => source, "lines" => lines}, fun) do
    lines = Enum.uniq(lines)

    case parse(source) do
      {:ok, ast} ->
        ctx = %{fun: fun, module: nil, owner: nil, form: :call}
        by_line = ast |> walk(ctx, []) |> Enum.group_by(& &1.line)
        Enum.map(lines, &classify(path, &1, Map.get(by_line, &1, [])))

      {:error, reason} ->
        Enum.map(lines, &unavailable(path, &1, "parse_error", reason))
    end
  end

  defp parse(source) do
    case Code.string_to_quoted(source, token_metadata: true, emit_warnings: false) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {location, message, token}} ->
        {:error, "line #{location[:line]}: #{text(message)}#{token}"}
    end
  end

  defp text({prefix, suffix}), do: prefix <> suffix
  defp text(message), do: message

  # One answer per line. Only a line whose candidates are all direct calls, with
  # one callee spelling and one supported owner, resolves.
  defp classify(path, line, []),
    do: unavailable(path, line, "no_call_candidate", "no call named like the target on this line")

  defp classify(path, line, candidates) do
    case {uniq(candidates, :form), uniq(candidates, :spelling), uniq(candidates, :owner)} do
      {[:call], [_], [{:ok, owner}]} ->
        {:site, %{path: path, line: line, status: "resolved", kind: "call", owner: owner}}

      {[:call], [_], [{reason, detail}]} ->
        unavailable(path, line, reason, detail)

      {[:call], [_], _owners} ->
        unavailable(path, line, "multiple_owners", "calls on this line have different owners")

      {[:call], spellings, _owners} ->
        unavailable(path, line, "ambiguous_callee", Enum.join(spellings, ", "))

      {forms, _spellings, _owners} ->
        unavailable(path, line, "not_direct_call", Enum.join(forms, ", "))
    end
  end

  defp uniq(candidates, key), do: candidates |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq()

  defp unavailable(path, line, reason, detail),
    do: {:unavailable, %{path: path, line: line, reason: reason, detail: detail}}

  # Collects target-named candidates, each with the owner of its innermost
  # supported ancestor: def-family clause, or test/setup/setup_all do-body.
  # Other forms (describe, if, case, for, fn, ...) are transparent.
  defp walk({:defmodule, _meta, [name, [{:do, body}]]}, ctx, acc),
    do: walk(body, %{ctx | module: module_name(name, ctx.module), owner: nil}, acc)

  defp walk({kind, _meta, args}, ctx, acc)
       when kind in [:defmodule, :defimpl, :defprotocol] and is_list(args),
       do: walk(args, %{ctx | module: :dynamic, owner: nil}, acc)

  defp walk({kind, _meta, [head | body]} = node, ctx, acc)
       when kind in @def_kinds and length(body) <= 1 do
    {call, guards} = split_guards(head)
    owner = def_owner(kind, call, node, ctx.module)
    walk([call_args(call), guards, body], %{ctx | owner: owner}, acc)
  end

  defp walk({kind, _meta, [_ | _] = args} = node, ctx, acc) when kind in @block_kinds do
    case Enum.split(args, -1) do
      {head, [[{:do, _} | _] = body]} ->
        owner = block_owner(kind, head, node, ctx.module)
        walk(body, %{ctx | owner: owner}, walk(head, ctx, acc))

      {_head, _last} ->
        walk(args, ctx, acc)
    end
  end

  defp walk({:&, _meta, [{:/, _, [{fun, meta, context}, _arity]}]}, %{fun: fun} = ctx, acc)
       when is_atom(context),
       do: [candidate(meta, :local, %{ctx | form: :capture}) | acc]

  defp walk({:&, _meta, args}, ctx, acc), do: walk(args, %{ctx | form: :capture}, acc)

  defp walk({:quote, _meta, args}, ctx, acc) when is_list(args),
    do: walk(args, %{ctx | form: :quote}, acc)

  defp walk({:@, _meta, [{attr, _, args}]}, ctx, acc) when attr in @spec_attrs and is_list(args),
    do: walk(args, %{ctx | form: :typespec}, acc)

  defp walk({{:., _, [receiver, fun]}, meta, args}, %{fun: fun} = ctx, acc) when is_list(args),
    do: walk([receiver | args], ctx, [candidate(meta, Macro.to_string(receiver), ctx) | acc])

  defp walk({fun, meta, args}, %{fun: fun} = ctx, acc) when is_list(args),
    do: walk(args, ctx, [candidate(meta, :local, ctx) | acc])

  defp walk({form, _meta, args}, ctx, acc) when is_list(args), do: walk([form | args], ctx, acc)
  defp walk({form, _meta, _context}, ctx, acc), do: walk(form, ctx, acc)
  defp walk({left, right}, ctx, acc), do: walk(right, ctx, walk(left, ctx, acc))
  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))
  defp walk(_literal, _ctx, acc), do: acc

  defp candidate(meta, spelling, ctx),
    do: %{
      line: meta[:line],
      form: ctx.form,
      spelling: spelling,
      owner: ctx.owner || module_body(ctx.module)
    }

  defp module_body(nil), do: {"no_owner", "top level"}
  defp module_body(_module), do: {"no_owner", "module body"}

  # Nested defmodule names are prefixed with the enclosing module, as in Elixir;
  # aliases do not change them. An Elixir.-prefixed name is absolute.
  defp module_name({:__aliases__, _, [:"Elixir" | parts]}, _outer),
    do: module_name({:__aliases__, [], parts}, nil)

  defp module_name({:__aliases__, _, parts}, outer) do
    if Enum.all?(parts, &is_atom/1),
      do: nest(outer, Enum.map_join(parts, ".", &Atom.to_string/1)),
      else: :dynamic
  end

  defp module_name(_name, _outer), do: :dynamic

  defp nest(nil, name), do: name
  defp nest(:dynamic, _name), do: :dynamic
  defp nest(outer, name), do: outer <> "." <> name

  defp split_guards({:when, _, [call | guards]}), do: {call, guards}
  defp split_guards(head), do: {head, []}

  defp call_args({_name, _meta, args}) when is_list(args), do: args
  defp call_args(_call), do: []

  defp def_owner(_kind, _call, _node, nil), do: {"no_owner", "top level"}
  defp def_owner(_kind, _call, _node, :dynamic), do: {"dynamic_identity", "module name"}

  defp def_owner(kind, {name, _, args}, node, module)
       when is_atom(name) and name not in [:unquote, :unquote_splicing] do
    args = List.wrap(args)

    {:ok,
     node
     |> owner(kind, module, name)
     |> Map.merge(%{
       arity: length(args),
       arity_ambiguous: Enum.any?(args, &match?({:\\, _, _}, &1))
     })}
  end

  defp def_owner(_kind, _call, _node, _module), do: {"dynamic_identity", "function name"}

  defp block_owner(_kind, _head, _node, nil), do: {"no_owner", "top level"}
  defp block_owner(_kind, _head, _node, :dynamic), do: {"dynamic_identity", "module name"}

  defp block_owner(:test, [name | _], node, module) when is_binary(name),
    do: {:ok, owner(node, :test, module, name)}

  defp block_owner(:test, _head, _node, _module), do: {"dynamic_identity", "test name"}
  defp block_owner(kind, _head, node, module), do: {:ok, owner(node, kind, module, nil)}

  defp owner({_, meta, _} = node, kind, module, name),
    do: %{kind: kind, module: module, name: name, line: meta[:line], end_line: max_line(node)}

  # Largest line in the owner's own metadata or any descendant, so the bound
  # always covers the owner's calls, including keyword do: bodies.
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
    nested =
      for key <- [:closing, :end, :end_of_expression, :last],
          pos = meta[key],
          is_list(pos),
          do: pos[:line]

    Enum.filter([meta[:line] | nested], &is_integer/1)
  end
end

DxOwners.main()
