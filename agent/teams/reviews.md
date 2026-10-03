# Reviews and replies

## Reviews

Tester and tech lead follow Google's [review comments](https://google.github.io/eng-practices/review/reviewer/comments.html) guide. Submit one review per pass, in one call, on the exact head:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
```

`tmp/review.json`: `{"commit_id": "<head SHA>", "event": "COMMENT", "body": "...", "comments": [{"path": "...", "line": 12, "body": "..."}]}`.

- Inline comments for local issues. The body for general issues and for lines outside the diff, as `path:line`.
- Make required changes clear and give the reason. Mark optional advice `Nit:`, `Optional:` or `FYI:`.
- Approval: line one is `LGTM` alone; line two is your role and session. Add scope or limits only when needed. Any other review starts with your role and session.
- Report what the linked CI run does not establish. Do not repeat the diff, the contract or passing checks.
- Write in plain, simple English. No mannered prose. Succinct and concise. Write like the reader has ADHD.

## Replies

`agent/teams/pr_review.py list "$PR"` prints the reviews of the last two reviewed heads and every unresolved thread with its IDs and reviewer; `--all` adds earlier heads. Fix the code where that answers a comment. Reply only when useful, to explain a fix, ask or disagree:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/comments/$REPLY_TO/replies" -f body="..."
```

The reviewer who opened a thread resolves it after checking, with `agent/teams/pr_review.py resolve "$THREAD"`. Optional advice may be declined. Feedback in a review body has no thread: its reviewer confirms it in the next review. Handoffs link the review and SHA.

