# PR review record

These requirements apply to every PR, pair or solo.

Agents share one GitHub identity, so native approval does not work. Submit one
`COMMENT` review per pass on the exact PR head, with findings inline:

```sh
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
```

Use this structure for `tmp/review.json`:

```json
{
  "commit_id": "<head SHA>",
  "event": "COMMENT",
  "body": "...",
  "comments": [{"path": "...", "line": 12, "body": "..."}]
}
```

For approval, put `LGTM` alone on the first line of the review body and the role
and session on the second line. Then publish the status:

```sh
agent/teams/publish_review.py --pr <pr> --sha <sha> --record <review URL>
```

The command refuses a wrong head, a wrong record or unresolved threads.

To read reviews and resolve threads:

| Command | Effect |
|---|---|
| `agent/teams/pr_review.py list <pr>` | Print recent reviews and every unresolved thread. |
| `agent/teams/pr_review.py resolve <thread>` | Resolve a thread. Only the reviewer who opened it may do this. |

Use `--owner-waiver` only on the user's explicit instruction.

## Finding format

Put one finding per inline comment, on the line it concerns.

- Review body: only the review decision, details the review record requires, check results and what you did not check (see [Evidence](../../AGENTS.md#github)), and findings outside the diff, each with its `path:line`.

- Findings: start with [P0, P1 or P2](README.md#severity) and the change you ask for, then explain why it matters. For wrong behaviour, give the steps or input, the actual result and the expected result; otherwise say what it breaks or costs. A `suggestion` block must replace the commented lines exactly.
