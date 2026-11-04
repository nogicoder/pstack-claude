---
name: babysit
description: Watch an open PR — fix failing CI and merge conflicts, hand review threads to the pr-review-addresser agent, and drive it to a mergeable state. Claude Code analog of Cursor's built-in /babysit. Use after opening a PR when the user wants the agent to shepherd it without re-prompting.
---

# Babysit a PR

On Codex, read the [platform mapping](../poteto-mode/references/codex-tools.md), including its per-skill notes, before following this skill.

On GitHub Copilot, read the [platform mapping](../poteto-mode/references/copilot-tools.md), including its per-skill notes, before following this skill.

On Muse, read the [platform mapping](../poteto-mode/references/muse-tools.md), including its per-skill notes, before following this skill.

Shepherd one open PR to mergeable. A background `Monitor` running `scripts/watch-pr.sh` wakes you when the PR changes. `<skill dir>` is this skill's base directory, which the Skill tool prints when it loads the skill. Inside a poteto-mode run, use its Babysit playbook instead.

## When to use

- There's an open PR and the user explicitly wants it kept green.
- The user invokes `/babysit` directly.
- A subagent that opens a PR does NOT babysit — return to the parent and let the parent decide.

## Steps

1. **Fetch PR state.**

   ```bash
   <skill dir>/scripts/watch-pr.sh <owner/repo> <number> once
   ```

   One line each: state, head, mergeable/mergeStateStatus, reviewDecision, each check, each unresolved thread (id, path, last comment by someone else), last review, last comment. `gh pr view` shows no unresolved threads. Read thread bodies only for threads that are new or changed.

2. **Triage in priority order.**
   - Merge conflicts (`mergeStateStatus == DIRTY`): run the **pstack:fix-merge-conflicts** skill. Force-push only if the branch is yours and not shared.
   - Branch `BEHIND` base, or a check failing in code the diff never touches: report it and ask before merging or rebasing base in. It restarts CI.
   - Failing checks (`conclusion: FAILURE`): run the **pstack:fix-ci** skill. Root-cause the failure; fix the underlying code or test; commit; push.
   - Review threads, from people and bots: spawn the **mob-pr-review:pr-review-addresser** agent. It validates, fixes, replies on and resolves them; do not do that work yourself. Spawn it once per review round, after the round's `last-review` line appears (a review posts all its threads at once), never once per thread. While it runs, do not edit, commit or push; events that arrive meanwhile wait until it returns. When it returns, put each question it stopped on to the user with `AskUserQuestion`, and pass the answers to the next addresser run. Then re-arm the watcher per step 3 if it has stopped.

3. **Watch.** Arm one `Monitor`: command `<skill dir>/scripts/watch-pr.sh <owner/repo> <number>`, `timeout_ms` 1800000, description `PR #<number> state change`. It polls every 60s and prints only changes (`+` new, `-` gone). Your own comments, replies and reviews are not changes. It exits when the PR is merged or closed. No `CronCreate`, `/loop`, sleep loops or `gh pr checks --watch`: cron ticks miss reviews for up to a full interval, and `--watch` exits early when a check waits on a person.
   - On an event: read only what changed, triage per step 2, keep waiting.
   - On the expiry notice: re-arm, unless `TaskList` shows a watcher for this PR still running. The script keeps its last snapshot in `$TMPDIR`, so the re-armed watcher reports what changed in the gap.
   - On `watch-error`: run step 1 by hand; report if `gh` auth or the network is down.
   - On `rate-limited until <time>`: do nothing. The watcher pauses and resumes by itself; do not set your own timer or start a second watcher.
   - Asked whether babysit is still running: answer from `TaskList`, not from memory.

4. **When to stop.**
   - Build is green, no unresolved threads, branch merges cleanly → call it ready.
   - Only checks or reviews that wait on a person remain (a manual check that stays PENDING with nothing running, a required approving review, a thread the addresser left open for its reviewer or a bot) → do not call it merge-ready. Name each one and who must act, and stop watching unless asked to keep going.
   - You've run three rounds of fix → push → recheck and it still isn't fully green → stop, summarise what's still broken, and hand control back.
   - The next fix would force a design choice → pause and put it to the user with `AskUserQuestion`.
   - Whenever you stop, `TaskStop` the monitor.

5. **Report.** Summarize fixes applied, comments addressed, comments deferred (with reason), current PR status. Cite each commit by SHA.

## Hard rules

- Don't rewrite history on a branch others may have pulled. If a rebase or force-push looks necessary, clear it with the user first.
- Don't tweak a test's expected values just to get a pass. Only change an assertion when the behaviour genuinely changed and the assertion was pinned to the old behaviour.
- Never skip hooks (`--no-verify`).
- Never bypass a failing check by marking it as not required.
- `gh pr ready` only when all checks are green and no unresolved review comments remain.

## Cross-refs

- Opening a PR does not start a babysit; inside poteto-mode the Babysit playbook owns the request and starts only when asked.
- Use `interrogate` before opening if the diff is contested; once open, babysit takes over.
- Use `unslop` on any prose you write here (PR comments, commit messages, status reports).
