manifest = "_build/dev/lib/mix_race/.mix/compile.elixir"
term = manifest |> File.read!() |> :erlang.binary_to_term()
source = term |> elem(2) |> Map.fetch!("lib/target.ex")
disk = File.read!("lib/target.ex")
digest = elem(source, 3)

IO.puts(
  "TRIAGE_JSON " <>
    JSON.encode!(%{
      target: MixRaceTarget.answer(),
      caller: MixRaceCaller.answer(),
      digest_matches_disk: digest == :crypto.hash(:blake2b, disk),
      stored_size: elem(source, 1),
      stored_mtime: elem(source, 2),
      disk_mtime: File.stat!("lib/target.ex", time: :posix).mtime,
      docs: inspect(Code.fetch_docs(MixRaceTarget))
    })
)
