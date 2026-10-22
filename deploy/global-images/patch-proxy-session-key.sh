#!/usr/bin/env bash
# 给运行中的 tdai-proxy 容器打补丁：session key 优先取 x-mavis-session-id。
#
# 原理：容器 entrypoint 是 `node --import tsx/esm src/index.ts`（直接跑 TS 源码，
# 没有 dist 产物），所以改 /app/src/session/session-key.ts 再 restart 即刻生效。
#
#   原始：
#     const id =
#       c.req.header("x-conversation-id") ??
#   改成：
#     const id =
#       c.req.header("x-mavis-session-id") ??
#       c.req.header("x-conversation-id") ??
#
# 实现：容器里没有 vim/python（只有 sh/sed/awk/perl/node），且镜像里的文件属主是
# app(10001) 而容器进程也跑在 app 上 —— 但被 docker cp 覆盖过的文件会变成 root:root
# 644，app 就写不进去了。所以统一走「docker cp 到宿主机改 → docker cp 盖回去 →
# 用 root 把属主还原」这条路，和你 vim 的思路一致，但可重复执行、可脚本化。
#
# 用法：
#   ./patch-proxy-session-key.sh                 # 打补丁 + 重启 + 等健康
#   ./patch-proxy-session-key.sh --dry-run       # 只看 diff，不落盘不重启
#   ./patch-proxy-session-key.sh --status        # 只看当前是否已打补丁
#   ./patch-proxy-session-key.sh --commit-image agentmemory/memory-proxy:patched
#                                            # 顺手 commit 成镜像，避免重建容器后丢
#
# ⚠️ 容器可写层的修改只扛得住 `docker restart`；`start-proxy.sh` 会
#    rm_container_if_exists + docker run 重建容器，改动就没了。
#    要长期生效请用 --commit-image，或直接改宿主机源码 MemoryProxy/src/session/
#    session-key.ts 后重新 build 镜像（仓库里那行已经加好了）。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

CONTAINER="${PROXY_CONTAINER:-tdai-proxy}"
REMOTE_PATH="${PROXY_SESSION_KEY_PATH:-/app/src/session/session-key.ts}"
NEW_HEADER="${PROXY_NEW_HEADER:-x-mavis-session-id}"
ANCHOR_HEADER="${PROXY_ANCHOR_HEADER:-x-conversation-id}"

DO_RESTART=1
RESTART_ALWAYS=0
DRY_RUN=0
STATUS_ONLY=0
COMMIT_TAG=""
WAIT_SECONDS=90

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)      CONTAINER="$2"; shift 2 ;;
    --path)           REMOTE_PATH="$2"; shift 2 ;;
    --header)         NEW_HEADER="$2"; shift 2 ;;
    --no-restart)     DO_RESTART=0; shift ;;
    --restart-always) RESTART_ALWAYS=1; shift ;;
    --dry-run|-n)     DRY_RUN=1; shift ;;
    --status)         STATUS_ONLY=1; shift ;;
    --commit-image)   COMMIT_TAG="$2"; shift 2 ;;
    --wait)           WAIT_SECONDS="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) die "未知参数：$1（-h 看用法）" ;;
  esac
done

DOCKER="$(find_docker)"

# ── 1. 前置检查 ───────────────────────────────────────────────────────────
$DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" \
  || die "容器 $CONTAINER 不存在。先用 ./start-proxy.sh 拉起来。"

NEW_LINE_TEXT="c.req.header(\"${NEW_HEADER}\") ??"

if (( STATUS_ONLY )); then
  info "当前 $CONTAINER:$REMOTE_PATH 状态："
  if $DOCKER exec "$CONTAINER" cat "$REMOTE_PATH" 2>/dev/null | grep -q "\"${NEW_HEADER}\""; then
    ok "已包含 $NEW_HEADER"
    $DOCKER exec "$CONTAINER" sh -c \
      "grep -n -A1 'const id =' '$REMOTE_PATH' | head -4"
    exit 0
  else
    warn "尚未包含 $NEW_HEADER（需要打补丁）"
    exit 1
  fi
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/patch-session-key.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
SRC="$WORKDIR/session-key.ts"
BAK="$WORKDIR/session-key.ts.bak"
OUT="$WORKDIR/session-key.ts.new"

# ── 2. 取出文件 + 记录原属主 ───────────────────────────────────────────────
info "从 $CONTAINER 取出 $REMOTE_PATH"
$DOCKER cp "$CONTAINER:$REMOTE_PATH" "$SRC"
cp "$SRC" "$BAK"

# docker cp 覆盖会把属主写成 root:root 644，而容器进程跑在 app(10001) 上，
# 盖回去之后还原成原属主，避免后续在容器内直接编辑失败。
ORIG_OWNER="$($DOCKER exec -u 0 "$CONTAINER" stat -c '%u:%g' "$REMOTE_PATH" 2>/dev/null || echo '10001:999')"
info "原属主 uid:gid = $ORIG_OWNER"

# ── 3. 幂等检查 ───────────────────────────────────────────────────────────
if grep -q "\"${NEW_HEADER}\"" "$SRC"; then
  if (( RESTART_ALWAYS )); then
    warn "已包含 $NEW_HEADER，仍按 --restart-always 强制走一遍（补丁不会重复插入）"
  else
    ok "已包含 $NEW_HEADER，无需改动"
    $DOCKER exec "$CONTAINER" sh -c "grep -n -B1 -A2 'const id =' '$REMOTE_PATH' | head -6"
    if (( DO_RESTART )); then
      info "重启 $CONTAINER（文件已符合预期）"
      $DOCKER restart "$CONTAINER" >/dev/null
      wait_healthy "$CONTAINER" "$WAIT_SECONDS"
      ok "$CONTAINER 已重启并健康"
    fi
    exit 0
  fi
fi

# ── 4. 打补丁 ─────────────────────────────────────────────────────────────
# 在 `const id =` 块里、anchor header（x-conversation-id）那一行之前插入一行，
# 缩进跟随 anchor 行；若 `const id =` 与 anchor 同行，则插在它后面。
set +e
awk -v NEWTEXT="$NEW_LINE_TEXT" -v ANCHOR="\"$ANCHOR_HEADER\"" '
  BEGIN { inblock = 0; found_block = 0; inserted = 0 }
  {
    if (!inblock && $0 ~ /^[ \t]*const[ \t]+id[ \t]*=/) {
      inblock = 1; found_block = 1
      print
      if (index($0, ANCHOR) > 0) {          # const id = c.req.header("x-...") 同行
        match($0, /^[ \t]*/)
        print substr($0, 1, RLENGTH) NEWTEXT
        inserted = 1
      }
      next
    }
    if (inblock) {
      if (index($0, ANCHOR) > 0 && !inserted) {
        match($0, /^[ \t]*/)
        print substr($0, 1, RLENGTH) NEWTEXT
        inserted = 1
      }
      print
      if ($0 ~ /^[ \t]*;/) inblock = 0         # 表达式结束
      next
    }
    print
  }
  END {
    if (!found_block) exit 3
    if (!inserted)   exit 4
  }
' "$SRC" > "$OUT"
AWK_RC=$?
set -e

case "$AWK_RC" in
  0) : ;;
  3) die "在 $CONTAINER:$REMOTE_PATH 里找不到 'const id =' 语句，文件结构与预期不符。上下文：
$(grep -n -m1 -B2 -A6 'conversation' "$SRC" || echo '(文件里没有 conversation 相关行)')" ;;
  4) die "找到了 'const id =' 块，但块内没有 anchor header \"$ANCHOR_HEADER\"。上下文：
$(sed -n '1,5p' "$SRC")" ;;
  *) die "awk 打补丁失败（exit=$AWK_RC）。" ;;
esac

# 结构自检：新行必须恰好出现一次，且 anchor 紧跟其后
[[ "$(grep -c -F "\"${NEW_HEADER}\"" "$OUT")" -eq 1 ]] \
  || die "补丁自检失败：$NEW_HEADER 行数不是 1。"
awk -v NEW="\"$NEW_HEADER\"" '
  { L[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (index(L[i], NEW) > 0) {
        if (i + 1 > NR || index(L[i + 1], "x-conversation-id") == 0) {
          print "anchor 未紧跟新行"; exit 5
        }
        exit 0
      }
    }
    print "找不到新行"; exit 5
  }
' "$OUT" || die "补丁自检失败：$NEW_HEADER 行后面不是 $ANCHOR_HEADER 行。"

info "补丁 diff："
diff -u --label "容器内(改前)" "$BAK" --label "容器内(改后)" "$OUT" || true

if (( DRY_RUN )); then
  warn "--dry-run：未写入容器、未重启。"
  exit 0
fi

# ── 5. 盖回容器 + 语法校验 + 还原属主 ─────────────────────────────────────
info "写回 $CONTAINER:$REMOTE_PATH"
$DOCKER cp "$OUT" "$CONTAINER:$REMOTE_PATH"
$DOCKER exec -u 0 "$CONTAINER" chown "$ORIG_OWNER" "$REMOTE_PATH"

# 容器里有 node(v22) 且直接跑 TS，node --check 能做语法校验；不支持则只提示不中断。
if $DOCKER exec "$CONTAINER" node --check "$REMOTE_PATH" 2>/dev/null; then
  ok "语法校验通过（node --check）"
else
  warn "node --check 未通过或不支持（node $( $DOCKER exec "$CONTAINER" node -v 2>/dev/null || echo '?' )）；"
  warn "若启动异常，用下面的命令回滚："
  warn "  $DOCKER exec -u 0 $CONTAINER cp $REMOTE_PATH $REMOTE_PATH.broken"
  warn "  $DOCKER cp $BAK $CONTAINER:$REMOTE_PATH && $DOCKER exec -u 0 $CONTAINER chown $ORIG_OWNER $REMOTE_PATH"
  warn "  $DOCKER restart $CONTAINER"
fi

# ── 6. 可选：commit 成镜像，避免重建容器后丢改动 ──────────────────────────
if [[ -n "$COMMIT_TAG" ]]; then
  info "commit 容器为镜像 $COMMIT_TAG"
  $DOCKER commit "$CONTAINER" "$COMMIT_TAG" >/dev/null
  ok "已保存镜像 $COMMIT_TAG —— 把 .env 的 PROXY_IMAGE 改成它，之后 start-proxy.sh 重建容器也不会丢"
fi

# ── 7. 重启 + 等健康 + 复核 ────────────────────────────────────────────────
if (( DO_RESTART )); then
  info "重启 $CONTAINER"
  $DOCKER restart "$CONTAINER" >/dev/null
  wait_healthy "$CONTAINER" "$WAIT_SECONDS"
  ok "$CONTAINER 已重启并健康"
else
  info "--no-restart：跳过重启"
fi

FINAL="$($DOCKER exec "$CONTAINER" sed -n '/const id =/,/;/p' "$REMOTE_PATH")"
echo "$FINAL" | grep -q "\"${NEW_HEADER}\"" || die "复核失败：重启后 $REMOTE_PATH 里没有 $NEW_HEADER"
info "复核通过，当前生效代码："
echo "$FINAL" | sed 's/^/    /'
