#!/bin/bash
# Usage: watch-pr.sh <owner/repo> <number> [once]
# Polls a PR every 60s and prints one line per change: "+ " new, "- " gone.
# Your own comments, replies and reviews do not count as changes.
# "once": print the current snapshot and exit.
# The last snapshot is kept in $TMPDIR, so a re-armed watcher also reports
# what changed while it was down. The first run ever is silent.
# Prints "watch-error: <msg>" after 5 failed polls in a row; backs off up to 10 min.
# Prints "rate-limited until HH:MMZ" once and pauses while the GraphQL quota is used up.
# Exits 0 once the PR is merged or closed.
set -u
repo=${1:?owner/repo}
number=${2:?PR number}
mode=${3:-watch}
owner=${repo%%/*}
name=${repo#*/}
state_file="${TMPDIR:-/tmp}/watch-pr-${owner}-${name}-${number}.state"

query='query($o:String!,$n:String!,$p:Int!){viewer{login}repository(owner:$o,name:$n){pullRequest(number:$p){
 state isDraft headRefOid mergeable mergeStateStatus reviewDecision
 commits(last:1){nodes{commit{statusCheckRollup{contexts(first:50){nodes{
  ... on CheckRun{name conclusion status} ... on StatusContext{context state}}}}}}}
 reviewThreads(first:100){nodes{id isResolved path
  comments(last:30){nodes{author{login} createdAt}}}}
 reviews(last:30){nodes{author{login} state submittedAt}}
 comments(last:30){nodes{author{login} createdAt}}}}}'

# Thread, review and comment lines carry only what others wrote, so your own
# replies leave them unchanged
jq_filter='.data.viewer.login as $me | .data.repository.pullRequest as $p |
 def others: [.[] | select(.author.login != $me)];
 "state=\($p.state) draft=\($p.isDraft)",
 "head=\($p.headRefOid[0:7])",
 "merge=\($p.mergeable)/\($p.mergeStateStatus)",
 "approval=\($p.reviewDecision // "none")",
 ($p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
   | "check \(.name // .context)=\(.conclusion // .state // .status)"),
 ($p.reviewThreads.nodes[] | select(.isResolved | not)
   | (.comments.nodes | others) as $c
   | "thread \(.id) \(.path) others=\($c | length) last=\($c[-1].author.login // "-")@\($c[-1].createdAt // "-")"),
 ($p.reviews.nodes | others | .[-1] // empty
   | "last-review \(.author.login) \(.state) \(.submittedAt)"),
 ($p.comments.nodes | others | .[-1] // empty
   | "last-comment \(.author.login)@\(.createdAt)")'

# Fails on gh's exit status, not on what the output looks like: a network
# error is plain text and must never be saved as a snapshot
snapshot() {
  local out
  out=$(gh api graphql -f query="$query" -f o="$owner" -f n="$name" -F p="$number" \
    --jq "$jq_filter" 2>&1) && [ -n "$out" ] || { echo "$out"; return 1; }
  sort <<<"$out"
}

# Epoch when the GraphQL quota resets, only while it is used up. The REST
# rate_limit endpoint does not count against the quota.
quota_reset() {
  gh api rate_limit --jq '.resources.graphql | select(.remaining == 0) | .reset' 2>/dev/null
}

if [ "$mode" = once ]; then
  snapshot
  exit
fi

failures=0
limited=
while true; do
  if cur=$(snapshot); then
    failures=0
    limited=
    if [ -f "$state_file" ]; then
      prev=$(cat "$state_file")
      if [ "$cur" != "$prev" ]; then
        comm -13 <(echo "$prev") <(echo "$cur") | sed 's/^/+ /'
        comm -23 <(echo "$prev") <(echo "$cur") | sed 's/^/- /'
      fi
    fi
    echo "$cur" >"$state_file"
    if grep -qE '^state=(MERGED|CLOSED)' <<<"$cur"; then
      grep -E '^state=' <<<"$cur"
      rm -f "$state_file"
      exit 0
    fi
  else
    reset=$(quota_reset)
    if [ -n "$reset" ]; then
      # Polling an empty quota only drains it for the user's other sessions
      if [ "$reset" != "$limited" ]; then
        limited=$reset
        echo "rate-limited until $(date -u -d "@$reset" +%H:%MZ 2>/dev/null || date -u -r "$reset" +%H:%MZ)"
      fi
      wait=$((reset - $(date +%s) + 5))
      sleep $((wait > 60 ? wait : 60))
      continue
    fi
    failures=$((failures + 1))
    if [ "$failures" -eq 5 ]; then
      echo "watch-error: $(tr '\n' ' ' <<<"$cur" | cut -c1-200)"
    fi
    # Back off 60s, 120s, 240s, 480s, then every 600s
    delay=$((60 << (failures < 5 ? failures - 1 : 4)))
    sleep $((delay < 600 ? delay : 600))
    continue
  fi
  sleep 60
done
