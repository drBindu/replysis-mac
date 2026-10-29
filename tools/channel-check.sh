#!/bin/bash
# Shows new messages from the other Claude (Windows or Mac) in CHANNEL.md, so the two stay in step without the owner
# carrying notes between them. Run by a Claude Code hook when a session starts and on every prompt; prints nothing when
# there is nothing new, so it costs no attention. Usage: channel-check.sh <repo dir> <Windows|Mac>
repo="$1"; me="$2"
case "$me" in Windows) other=Mac ;; Mac) other=Windows ;; *) exit 0 ;; esac
cd "$repo" 2>/dev/null || exit 0
git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=8 fetch -q origin main 2>/dev/null || exit 0
new=$(git rev-parse -q --verify origin/main:CHANNEL.md 2>/dev/null) || exit 0
seen_file=.git/channel-seen-$me
old=$(cat "$seen_file" 2>/dev/null)
[ "$new" = "$old" ] && exit 0
if [ -n "$old" ] && git cat-file -e "$old" 2>/dev/null; then
  added=$(git diff "$old" "$new" | grep '^+' | grep -v '^+++' | cut -c2-)
else
  added=$(git cat-file -p "$new")
fi
echo "$new" > "$seen_file"
echo "$added" | grep -q "^## .* From $other" || exit 0
echo "NEW MESSAGE FROM $(echo "$other" | tr a-z A-Z) CLAUDE in CHANNEL.md (drBindu/replysis-mac):"
echo "$added"
echo "Act on it if it is yours to do, tell the owner in one line, and reply by appending a '## <date time> From $me' section to CHANNEL.md, then commit and push (git pull --rebase first)."
