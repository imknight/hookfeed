#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
seed=0 hooks=50 reader=0 drain=0 expect_zero=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --seed) seed="$2"; shift 2 ;;
        --hooks) hooks="$2"; shift 2 ;;
        --reader) reader="$2"; shift 2 ;;
        --drain) drain=1; shift ;;
        --expect-zero-loss) expect_zero=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$seed" =~ ^[0-9]+$ && "$hooks" =~ ^[0-9]+$ && "$reader" =~ ^[01]$ ]] || exit 2
binary="${HOOKFEED_CLI:-$root/.build-cli/debug/hookfeed}"
[ -x "$binary" ] || { echo 'Build first: swift build --scratch-path .build-cli --product hookfeed' >&2; exit 2; }
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/hookfeed-burst.XXXXXX")"
reader_pid=""
cleanup() {
    touch "$task_dir/stop"
    if [ -n "$reader_pid" ]; then wait "$reader_pid" || true; fi
    rm -rf "$task_dir"
}
trap cleanup EXIT
export HOOKFEED_STORE_PATH="$task_dir/inbox.sqlite" HOOKFEED_LOG_PATH="$task_dir/hook.log"
unset HOOKFEED_URL HOOKFEED_TOKEN
"$binary" send initialize >/dev/null
python3 - "$HOOKFEED_STORE_PATH" "$seed" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('DELETE FROM messages')
    db.executemany('INSERT INTO messages(id,title,body,source,kind,thread_key,received_at) VALUES (?,?,?,?,?,?,?)',
                   ((f'seed-{i}',f'Seed {i}','x'*1000,'run','completed',f't{i%500}',1790000000+i) for i in range(int(sys.argv[2]))))
PY
if [ "$reader" = 1 ]; then
    (while [ ! -f "$task_dir/stop" ]; do
        sqlite3 -cmd '.timeout 5000' "$HOOKFEED_STORE_PATH" 'select * from messages order by seq desc' >/dev/null
        sleep 0.1
    done) &
    reader_pid=$!
fi
start="$(python3 -c 'import time; print(time.time())')"
pids=()
for ((i=0; i<hooks; i++)); do
    printf '{"session_id":"burst-%s","cwd":"/tmp","hook_event_name":"Stop","last_assistant_message":"Done %s"}' "$i" "$i" |
        "$binary" hook claude-code >"$task_dir/stdout-$i" 2>"$task_dir/stderr-$i" &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
end="$(python3 -c 'import time; print(time.time())')"
touch "$task_dir/stop"
if [ -n "$reader_pid" ]; then wait "$reader_pid"; reader_pid=""; fi
if [ "$drain" = 1 ]; then "$binary" drain >/dev/null; fi
stored="$(sqlite3 "$HOOKFEED_STORE_PATH" "select count(*) from messages where thread_key like 'claude-code:burst-%'")"
python3 - "$task_dir" "$seed" "$hooks" "$reader" "$stored" "$start" "$end" "$expect_zero" <<'PY'
import pathlib,sys
folder,seed,hooks,reader,stored,start,end,expect=sys.argv[1:]
assert all(p.stat().st_size==0 for p in pathlib.Path(folder).glob('stdout-*')), 'Hook wrote to stdout'
lost=int(hooks)-int(stored)
print(f'seed={seed} hooks={hooks} reader={reader} stored={stored} lost={lost} wall={float(end)-float(start):.2f}s')
sys.exit(1 if expect=='1' and lost else 0)
PY
