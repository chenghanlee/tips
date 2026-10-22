# Test logs

For every `mix test` invocation, including one test, one file and reruns, run from the
clone's root: `mkdir -p tmp && mix test <args> > tmp/<name>.log 2>&1; echo "exit=$?"`,
with a new `<name>` per run. The printed `exit=` is the result. On `exit=0`, read
`tail -n 10 tmp/<name>.log` and stop. On any other exit, run
`grep -n -E 'failure|error|seed|\*\*' tmp/<name>.log | head -n 40`, then `sed -n` at
most 60 lines around the first failure. Never `cat` or Read the whole log.
