#!/bin/bash
# Usage: watch-pr.test.sh [path/to/watch-pr.sh]
# Runs watch-pr.sh against a fake gh and a fake sleep, replaying outages seen in
# real babysit sessions. Exits 1 on the first failed case.
set -u
script=${1:-$(dirname "$0")/watch-pr.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

# Fake gh: graphql call N prints $tmp/case/N.out and exits with $tmp/case/N.rc.
# rate_limit prints $tmp/case/reset when that file exists.
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/bash
dir=$FAKE_CASE
if [ "$2" = rate_limit ]; then
  [ -f "$dir/reset" ] && [ "$(cat "$dir/calls")" -lt "$(cat "$dir/recover")" ] && cat "$dir/reset"
  exit 0
fi
n=$(($(cat "$dir/calls") + 1)); echo $n >"$dir/calls"
cat "$dir/$n.out"
exit "$(cat "$dir/$n.rc" 2>/dev/null || echo 0)"
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/bin/bash
echo "$1" >>"$FAKE_CASE/sleeps"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"

ok='state=OPEN draft=false
check verify=SUCCESS
merge=MERGEABLE/CLEAN'
merged='state=MERGED draft=false
check verify=SUCCESS
merge=MERGEABLE/CLEAN'

# new_case <name> then step <out> [rc] per graphql call
new_case() { case_dir=$tmp/$1; mkdir "$case_dir"; echo 0 >"$case_dir/calls"; steps=0; }
step() { steps=$((steps + 1)); printf '%s\n' "$1" >"$case_dir/$steps.out"; echo "${2:-0}" >"$case_dir/$steps.rc"; }
run() {
  rm -f "$tmp"/watch-pr-*.state
  PATH="$tmp/bin:$PATH" TMPDIR=$tmp FAKE_CASE=$case_dir "$script" o/r 1 2>&1
}
fail() { echo "FAIL $1"; echo "$2" | sed 's/^/  | /'; exit 1; }

# 6b3595e3, 510dcd33: a network blip was saved as the snapshot, so every line
# showed as gone and then as new
new_case network-blip
step "$ok"
step "error connecting to api.github.com" 1
step "$ok"
step "$merged"
out=$(run)
grep -q 'error connecting' <<<"$out" && fail network-blip "$out"
grep -q '^- check' <<<"$out" && fail network-blip "$out"
[ "$(grep -c '^state=MERGED' <<<"$out")" = 1 ] || fail network-blip "$out"
echo "ok network-blip"

# f1fc3a99, e5b876df: the watcher kept polling every 60s against a used-up quota
new_case rate-limit
step "$ok"
step "gh: API rate limit already exceeded for user ID 43837352." 1
step "gh: API rate limit already exceeded for user ID 43837352." 1
step "$ok"
step "$merged"
echo $(($(date +%s) + 300)) >"$case_dir/reset"
echo 4 >"$case_dir/recover"
out=$(run)
[ "$(grep -c '^rate-limited until' <<<"$out")" = 1 ] || fail rate-limit "$out"
grep -q '^watch-error' <<<"$out" && fail rate-limit "$out"
# only the two good polls may sleep the normal 60s
[ "$(awk '$1 < 290' "$case_dir/sleeps" | wc -l)" -eq 2 ] || fail rate-limit "sleeps: $(tr '\n' ' ' <"$case_dir/sleeps")"
echo "ok rate-limit"

# Other errors back off instead of polling every 60s, and report once
new_case backoff
step "$ok"
for _ in 1 2 3 4 5 6; do step '{"message":"Bad credentials"}' 1; done
step "$merged"
out=$(run)
[ "$(grep -c '^watch-error' <<<"$out")" = 1 ] || fail backoff "$out"
[ "$(tr '\n' ' ' <"$case_dir/sleeps")" = "60 60 120 240 480 600 600 " ] || fail backoff "sleeps: $(tr '\n' ' ' <"$case_dir/sleeps")"
echo "ok backoff"

# once: exit status follows gh
new_case once
step "error connecting to api.github.com" 1
PATH="$tmp/bin:$PATH" TMPDIR=$tmp FAKE_CASE=$case_dir "$script" o/r 1 once >/dev/null && fail once "exit 0 on gh failure"
echo "ok once"
