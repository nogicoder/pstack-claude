#!/bin/bash
# Usage: watch-pr.sh <owner/repo> <number> [once]
# Polls a PR every 60s and prints one line per change: "+ " new, "- " gone.
# Your own comments, replies and reviews do not count as changes.
# "once": print the current snapshot and exit.
# The last snapshot is kept in $TMPDIR, so a re-armed watcher also reports
# what changed while it was down. The first run ever is silent.
# Prints "watch-error: <msg>" after 5 failed polls in a row.
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

snapshot() {
  gh api graphql -f query="$query" -f o="$owner" -f n="$name" -F p="$number" \
    --jq "$jq_filter" 2>&1 | sort
}

# gh errors come back as a "gh: " line or the raw JSON response
failed() { [ -z "$1" ] || grep -qE '^(gh: |\{)' <<<"$1"; }

if [ "$mode" = once ]; then
  cur=$(snapshot)
  echo "$cur"
  failed "$cur" && exit 1
  exit 0
fi

failures=0
while true; do
  cur=$(snapshot)
  if ! failed "$cur"; then
    failures=0
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
    failures=$((failures + 1))
    if [ "$failures" -eq 5 ]; then
      echo "watch-error: $(head -1 <<<"$cur")"
    fi
  fi
  sleep 60
done
