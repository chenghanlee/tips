# Reviews and replies

## Reviews

Load the [github-comments skill](../skills/github-comments/SKILL.md) before writing a review or reply. Tester and tech lead follow Google's [review comments](https://google.github.io/eng-practices/review/reviewer/comments.html) guide. Review format:

- Approval: `LGTM` alone on line one; role and session on line two. A tech lead puts the tester's approving review link on line three.
- Other reviews: role and session on line one.
- Include relevant scope, limits and pending checks. The approving review must include chat decisions absent from PR threads; it closes the decision record without a separate closing note.

Submit one review per pass, in one call, on the exact head:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
```

`tmp/review.json`: `{"commit_id": "<head SHA>", "event": "COMMENT", "body": "...", "comments": [{"path": "...", "line": 12, "body": "..."}]}`.

## Replies

`agent/teams/pr_review.py list "$PR"` prints the reviews of the last two reviewed heads and every unresolved thread with its IDs and reviewer; `--all` adds earlier heads. To reply:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/comments/$REPLY_TO/replies" -f body="..."
```

The reviewer who opened a thread resolves it after checking, with `agent/teams/pr_review.py resolve "$THREAD"`. Optional advice may be declined. Feedback in a review body has no thread: its reviewer confirms it in the next review. Handoffs link the review and SHA.
