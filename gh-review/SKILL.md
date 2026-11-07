---
name: gh-review
description: Handle GitHub PR review comments end-to-end. Fetches all unresolved review threads on the current PR, spawns parallel subagents to fix each comment, replies to each thread describing the fix, commits and pushes, re-requests GitHub Copilot review, then loops every 10 minutes until all comments are resolved and CI is green. Trigger whenever the user says "handle the review", "address review comments", "fix the PR feedback", "respond to comments", "work through the review", "deal with the review comments", or any variant of acting on GitHub PR review feedback.
---

# GitHub PR Review Handler

End-to-end loop: fetch unresolved comments → fix in parallel → reply → push → re-trigger Copilot → wait → repeat until clean.

## Step 1: Orient

```bash
# Get PR context
gh pr view --json number,headRefName,url,baseRefName
```

Derive OWNER and REPO from `gh repo view --json owner,name`. If there's no open PR on the current branch, tell the user and stop.

## Step 2: Fetch unresolved threads

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 10) {
            nodes {
              id
              databaseId
              body
              path
              line
              author { login }
              url
            }
          }
        }
      }
    }
  }
}' -f owner=OWNER -f repo=REPO -F number=PR_NUMBER
```

Keep only threads where `isResolved: false` and `isOutdated: false`.

If none remain, jump to **Step 4 (exit check)**.

## Step 3: Fix comments in parallel

Spawn one subagent per unresolved thread. Launch all at once — don't wait for one before starting the next.

Brief each subagent:

```
You are triaging and (if needed) fixing a PR review comment. Here is the thread:

File: <path>
Line: <line>
Comment from <author>: "<body>"
Thread ID: <graphql_id>
First comment database ID: <databaseId>  ← needed for reply
Comment URL: <url>

Instructions:

FIRST — verify whether this is a real issue or a misunderstanding of the architecture.
Read the file, the surrounding code, any relevant ADRs in docs/kos/adr/, and the glossary
(docs/kos/glossary.md). Ask yourself: is the reviewer's concern valid given how this system
actually works, or are they missing context about an intentional design decision?

- If it's a misunderstanding: do NOT change any code. Set outcome=clarification and write
  a reply_body that explains the design clearly — reference the specific invariant, ADR, or
  architectural reason that makes the current code correct. Be respectful and precise.

- If it's a real issue: make the minimal fix. Prefer editing in-place; only touch other files
  if the fix genuinely requires it. Set outcome=fixed.

- If you genuinely can't tell or the fix is too risky without more context: set outcome=escalate
  and explain what you need to know.

Do NOT commit, push, or reply to the comment — the parent handles that.

Report back:
  - outcome: "fixed" | "clarification" | "escalate"
  - files_changed: list of files modified (empty if clarification/escalate)
  - reply_body: the reply text to post on the thread
  - thread_id: <graphql_id>
  - reply_to_id: <databaseId>
```

Collect all reports before proceeding.

## Step 4: Commit, reply, push

Split reports by outcome:

- **escalate** → surface to the user immediately with the comment URL and what the subagent needs. Do not proceed with the loop until the user responds.
- **clarification** → no code change; reply with the explanation the subagent wrote.
- **fixed** → stage and commit.

**Commit** (only if any `fixed` outcomes):

```bash
git add <files from fixed reports only>
git commit -m "fix: address PR review comments"
```

**Reply to every thread** (both fixed and clarification) using the subagent's `reply_body`:

```bash
gh api repos/OWNER/REPO/pulls/PR_NUMBER/comments \
  --method POST \
  -f body="<reply_body>" \
  -F in_reply_to=<reply_to_id>
```

**Push** (only if there were fixes):

```bash
git push
```

## Step 5: Check exit condition

Re-fetch threads and CI state:

```bash
gh pr checks --json name,state,conclusion
```

**Ignore** any check whose name contains `snyk` or `sca` (case-insensitive).

**Exit (success) if:**
- No unresolved, non-outdated review threads remain, AND
- All non-ignored CI checks have `conclusion: SUCCESS` (or `state: success`)

Tell the user: "PR is clean — all review threads resolved and CI is green. Ready for merge." Then stop.

**Otherwise:** re-request Copilot review and loop:

```bash
gh api repos/OWNER/REPO/pulls/PR_NUMBER/requested_reviewers \
  --method POST \
  -f 'reviewers[]=copilot'
```

Then schedule the next check:

```
ScheduleWakeup(delaySeconds=600, prompt="/gh-review", reason="waiting for Copilot re-review and CI")
```

## Notes

- If a subagent can't figure out how to fix a comment, it should report that back instead of guessing. Surface those to the user after the commit/push step with the comment URL so they can handle it manually.
- If CI is failing on something unrelated to the review comments (not Snyk/SCA), flag it to the user rather than looping forever.
- Each loop iteration only re-fetches threads — previous iterations' replies are already there.
