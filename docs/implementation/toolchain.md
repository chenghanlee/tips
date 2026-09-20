# Tips toolchain

This is the version decision for [P0.01](https://github.com/chenghanlee/tips/issues/22), dated 2026-09-21. Exact pins select inputs for probes; they do not certify the complete application. P16.00 owns SaladUI compatibility and P0.06 owns the combined database image and SQL proof.

## Runtime and generator

| Component | Exact selection | Status and primary source |
|---|---|---|
| Elixir | 1.20.4 | Pinned; installed locally. [Release](https://github.com/elixir-lang/elixir/releases/tag/v1.20.4) |
| Erlang/OTP | 29.1 | Pinned; local `OTP_VERSION` is 29.1. [Release](https://github.com/erlang/otp/releases/tag/OTP-29.1) |
| Hex | 2.5.1 | Pinned; installed locally. [Release](https://github.com/hexpm/hex/releases/tag/v2.5.1) |
| Phoenix installer / framework | 1.8.14 | Pinned. [Installer](https://hex.pm/packages/phx_new/1.8.14), [framework](https://hex.pm/packages/phoenix/1.8.14) |
| PostgreSQL | 18.6 | Pinned for the probe; local Homebrew server has no pgvector or pg_textsearch. [Release](https://www.postgresql.org/docs/18/release-18-6.html) |

Keep a single Phoenix application with PostgreSQL, Bandit, LiveView, Ecto, mailer and generated asset tooling. Retain integer primary keys. Run the generator outside this repository; do not commit generated application code in this task.

The dependency matrix, generator/compiler/test evidence, browser decision, database build requirements and Markdown policy are still being collected. This document remains a draft until all five acceptance scenarios have evidence.
