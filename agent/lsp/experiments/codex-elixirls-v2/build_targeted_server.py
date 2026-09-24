#!/usr/bin/env python3
"""Generate an isolated ElixirLS path-invalidation prototype from pinned source."""
import argparse
import difflib
import json
import os
from pathlib import Path
import shutil
import subprocess

from build_compiler_comparison import replace


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--seed', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    source = root / 'elixir-ls'
    for directory in ['elixir-ls', 'hex-home', 'install-cache']:
        if not (root / directory).exists():
            shutil.copytree(args.seed / directory, root / directory)
    base = Path('apps/language_server/lib/language_server')
    server_name, build_name = base / 'server.ex', base / 'build.ex'
    old_server = (args.upstream / server_name).read_text()
    old_build = (args.upstream / build_name).read_text()
    server = replace(old_server, '\n    needs_build?: false,',
                     '\n    pending_changed_files: MapSet.new(),\n'
                     '    in_flight_changed_files: MapSet.new(),\n'
                     '    build_pid: nil,\n    build_timer: nil,\n    needs_build?: false,')
    server = replace(server,
        '      state = update_in(state.source_files[uri], &%{&1 | dirty?: false})\n      trigger_build(state)',
        '      state = update_in(state.source_files[uri], &%{&1 | dirty?: false})\n'
        '      trigger_build(state, [SourceFile.Path.from_uri(uri)])')
    server = replace(server, '    needs_build =\n      Enum.any?(changes,',
                     '    build_changes =\n      Enum.filter(changes,')
    server = replace(server, '    if needs_build do\n      trigger_build(state)',
                     '    if build_changes != [] do\n'
                     '      trigger_build(state, Enum.map(build_changes, &SourceFile.Path.from_uri(&1.uri)))')
    server = replace(server,
        '         state = %__MODULE__{project_dir: project_dir, full_build_done?: full_build_done?}\n       ) do\n    cond do',
        '         state = %__MODULE__{project_dir: project_dir},\n'
        '         changed_files \\\\ []\n       ) do\n'
        '    state = %{state | pending_changed_files: MapSet.union(state.pending_changed_files, MapSet.new(changed_files))}\n\n'
        '''    if is_binary(project_dir) do
      # A fixed window, not a sliding debounce. Later notifications cannot
      # postpone the scheduled build. Events during compilation form its successor.
      unless state.needs_build?, do: JsonRpc.telemetry("build_queued", %{}, %{})

      timer =
        if state.build_running? or state.build_timer do
          state.build_timer
        else
          :erlang.start_timer(250, self(), :start_build)
        end

      %{state | build_timer: timer, needs_build?: true, analysis_ready?: false}
    else
      state
    end
  end

  defp start_build(
         state = %__MODULE__{project_dir: project_dir, full_build_done?: full_build_done?}
       ) do
    cond do''')
    server = replace(server, '  @impl GenServer\n  def handle_info(:default_config,', '''  @impl GenServer
  def handle_info({:timeout, ref, :start_build}, state = %__MODULE__{build_timer: ref}) do
    {:noreply, start_build(%{state | build_timer: nil})}
  end

  @impl GenServer
  def handle_info(:default_config,''')
    server = replace(server, '          force?: not full_build_done?',
                     '          force?: not full_build_done?,\n'
                     '          changed_files: MapSet.to_list(state.pending_changed_files)')
    server = replace(server, '            | build_ref: build_ref,\n              needs_build?: false,',
                     '            | build_ref: build_ref,\n'
                     '              build_pid: build_pid,\n'
                     '              in_flight_changed_files: state.pending_changed_files,\n'
                     '              pending_changed_files: MapSet.new(),\n              needs_build?: false,')
    server = replace(server, '        {_pid, build_ref} =', '        {build_pid, build_ref} =')
    server = replace(server, '    state = %{state | build_running?: false}', '''    # A successful Mix compilation acknowledges only its own batch. Any
    # unacknowledged paths survive failure, skipped compilation, or worker exit.
    # Retention alone does not schedule another build and cannot spin on errors.
    state = %{
      state
      | build_running?: false,
        build_pid: nil,
        pending_changed_files: MapSet.union(state.pending_changed_files, state.in_flight_changed_files),
        in_flight_changed_files: MapSet.new()
    }''')
    server = replace(server, '  def dialyzer_finished(server', '''  def compilation_finished(server) do
    GenServer.cast(server, {:compilation_finished, self()})
  end

  def dialyzer_finished(server''')
    server = replace(server, '  @impl GenServer\n  def handle_cast({:build_finished,', '''  @impl GenServer
  def handle_cast({:compilation_finished, pid}, state = %__MODULE__{build_pid: pid}) do
    {:noreply, %{state | in_flight_changed_files: MapSet.new()}}
  end

  def handle_cast({:compilation_finished, _pid}, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast({:build_finished,''')
    build = replace(old_build, 'run_mix_compile(Keyword.get(opts, :force?, false))',
                    'run_mix_compile(Keyword.get(opts, :force?, false), Keyword.get(opts, :changed_files, []))')
    build = replace(build, '  defp run_mix_compile(force?) do',
                    '  defp run_mix_compile(force?, changed_files) do')
    build = replace(build, '    case Mix.Task.run("compile", opts) do',
                    '    opts = opts ++ Enum.flat_map(changed_files, &["--force-path", &1])\n\n'
                    '    case Mix.Task.run("compile", opts) do')
    build = replace(build, '      compile_diagnostics =\n',
                    '      if status in [:ok, :noop], do: Server.compilation_finished(parent)\n\n'
                    '      compile_diagnostics =\n')
    helper_name = Path('apps/language_server/test/support/server_test_helpers.ex')
    test_name = Path('apps/language_server/test/server_test.exs')
    old_helper = (args.upstream / helper_name).read_text()
    old_test = (args.upstream / test_name).read_text()
    # Scheduled work is not idle. Update the existing test helper and the one
    # test that assumes compilation after didSave takes less than 100 ms.
    helper = replace(old_helper, 'if state.build_running? do',
                     'if state.build_running? or state.build_timer != nil do')
    test = replace(old_test,
        '        Server.receive_packet(server, did_save(uri))\n\n'
        '        assert_receive notification("window/logMessage", %{\n'
        '                         "message" => "Compile took" <> _',
        '        Server.receive_packet(server, did_save(uri))\n'
        '        wait_until_compiled(server)\n\n'
        '        assert_receive notification("window/logMessage", %{\n'
        '                         "message" => "Compile took" <> _')
    patches = []
    for name, old, new in [(server_name, old_server, server), (build_name, old_build, build),
                           (helper_name, old_helper, helper), (test_name, old_test, test)]:
        (source / name).write_text(new)
        env = os.environ | {'ERL_FLAGS': '+S 4:4', 'HEX_HOME': str(root / 'hex-home')}
        p = subprocess.run(['unbuffer', 'mix', 'format', str(name)], cwd=source,
                           env=env, capture_output=True, text=True, timeout=60)
        assert p.returncode == 0, p.stdout + p.stderr
        patches.append(''.join(difflib.unified_diff(old.splitlines(True),
            (source / name).read_text().splitlines(True), fromfile='a/' + str(name), tofile='b/' + str(name))))
    (root / 'candidate.patch').write_text(''.join(patches))
    print(json.dumps({'source': str(source), 'patch': str(root / 'candidate.patch')}))


if __name__ == '__main__':
    main()
