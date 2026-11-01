#!/usr/bin/env bash
# 一键拉起 memory → memory-hub → proxy 三件套，**在 proxy 启动前**就把
# session key 补丁打进去（session key 优先取 x-mavis-session-id）。
#
# 与 start-all.sh 的关系：
#   - start-all.sh 保持原样 —— 不带补丁的干净启动；
#   - 本脚本在启动流程里多一步「构建打过补丁的 proxy 镜像」：
#       1. 从 base 镜像里取出 /app/src/session/session-key.ts；
#       2. 在宿主机上插入 x-mavis-session-id 那一行；
#       3. docker build 派生新镜像 <base>:patched-sessionkey
#          （只多一层 COPY，ENTRYPOINT/CMD/USER 与原镜像一致）；
#       4. 用这个镜像启动 proxy —— 容器一起来就是打过补丁的版本，
#          不再有「先跑起来再 patch 再重启」的中间态。
#
# 为什么走镜像而不是直接改容器可写层：
#   直接改可写层只在 docker restart 期间有效，容器一重建就没了；
#   派生镜像后，每次启动都从镜像起，补丁稳定生效。
#
# 本脚本不改动任何原有脚本：镜像 tag 通过一份临时的 .env 副本传给
# start-proxy.sh（临时副本用完即删，用户的 .env 不受影响）。
#
# 用法（与 start-all.sh 完全一致）：
#   ./start-all-patch.sh            # 交互式引导填写 LLM，通过后一键起
#   PULL=1 ./start-all-patch.sh     # 先 docker pull 三个镜像，升级到最新 latest
#
# 可调参数（写进 .env 或临时用环境变量覆盖）：
#   PROXY_IMAGE                 base 镜像（默认取 .env）
#   PROXY_PATCHED_IMAGE         补丁镜像 tag（默认 <base>:patched-sessionkey）
#   PROXY_SESSION_KEY_PATH      补丁目标文件（默认 /app/src/session/session-key.ts）
#   PROXY_NEW_HEADER            插入的 header（默认 x-mavis-session-id）
#   PROXY_ANCHOR_HEADER         锚点 header（默认 x-conversation-id）

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

PROXY_SESSION_KEY_PATH="${PROXY_SESSION_KEY_PATH:-/app/src/session/session-key.ts}"
PROXY_NEW_HEADER="${PROXY_NEW_HEADER:-x-mavis-session-id}"
PROXY_ANCHOR_HEADER="${PROXY_ANCHOR_HEADER:-x-conversation-id}"

# .env 不存在时从模板复制（交互式流程会引导填写 LLM）
if [[ ! -f "$ENV_FILE" ]]; then
  info ".env 不存在，从 .env.example 复制一份"
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
fi

load_env

# 交互式确认 LLM 两组配置 + 通路检查 + 写回 .env
interactive_llm_setup

require_vars \
  MEMORY_CORE_IMAGE MEMORY_HUB_IMAGE PROXY_IMAGE \
  MEMORY_CORE_PORT PANEL_PORT KNOWLEDGE_PORT PROXY_PORT \
  MEMORY_CORE_VOLUME PANEL_VOLUME \
  MEMORY_LLM_BASE_URL MEMORY_LLM_API_KEY MEMORY_LLM_MODEL \
  KNOWLEDGE_PUBLIC_BASE_URL \
  PROXY_UPSTREAM_URL PROXY_UPSTREAM_API_KEY PROXY_UPSTREAM_MODEL

# 端口预检：一次性检查 4 个目标端口，被外部进程占用则报错退出
check_ports

# ── patch 插入逻辑 ───────────────────────────────────────────────────────
# 在 `const id =` 块里、anchor header 那一行之前插入一行，缩进跟随 anchor 行；
# 若 `const id =` 与 anchor 同行，则插在它后面。
# 用法：patch_session_key_file <src> <out> <new_header> <anchor_header> <label>
#   src 不动，结果写 out；幂等由调用方负责（src 已含 new header 时不要调用）。
patch_session_key_file() {
  local src="$1" out="$2" label="$3"
  local new_header="$4" anchor_header="$5"
  local new_line_text="c.req.header(\"${new_header}\") ??"
  local rc

  set +e
  awk -v NEWTEXT="$new_line_text" -v ANCHOR="\"$anchor_header\"" '
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
' "$src" > "$out"
  rc=$?
  set -e

  case "$rc" in
    0) : ;;
    3) die "在 $label 里找不到 'const id =' 语句，文件结构与预期不符。上下文：
$(grep -n -m1 -B2 -A6 'conversation' "$src" || echo '(文件里没有 conversation 相关行)')" ;;
    4) die "在 $label 里找到了 'const id =' 块，但块内没有 anchor header \"$anchor_header\"。上下文：
$(sed -n '1,5p' "$src")" ;;
    *) die "打补丁失败（awk exit=$rc）。" ;;
  esac

  # 结构自检：新行必须恰好出现一次，且 anchor 紧跟其后
  [[ "$(grep -c -F "\"${new_header}\"" "$out")" -eq 1 ]] \
    || die "补丁自检失败：$new_header 行数不是 1。"
  awk -v NEW="\"${new_header}\"" -v ANCHOR="\"${anchor_header}\"" '
  { L[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (index(L[i], NEW) > 0) {
        if (i + 1 > NR || index(L[i + 1], ANCHOR) == 0) {
          print "anchor 未紧跟新行"; exit 5
        }
        exit 0
      }
    }
    print "找不到新行"; exit 5
  }
' "$out" || die "补丁自检失败：$new_header 行后面不是 $anchor_header 行。"
}

# ── 构建打过补丁的 proxy 镜像 ────────────────────────────────────────────
# build_patched_image <base_image> <target_tag>
#   create 临时容器取出源文件 → 宿主机打补丁 → docker build 派生新镜像。
#   用 build 而不是 commit：commit 会把临时容器的 entrypoint 覆盖（原本打算
#   用它跑 chown）一起固化进镜像，proxy 就起不来了。build 只加一层 COPY，
#   镜像的 ENTRYPOINT/CMD/USER 原样保留。
build_patched_image() {
  local base_image="$1" target_tag="$2"
  local tmp_ct="tdai-proxy-patch-build.$$"
  local workdir owner src out image_user

  # 本地没有 base 镜像就拉一次（docker create 不会像 docker run 那样自动拉）
  if ! $DOCKER image inspect "$base_image" >/dev/null 2>&1; then
    info "本地没有 $base_image，先拉取"
    $DOCKER pull "$base_image" >/dev/null || die "拉取 $base_image 失败。"
  fi

  info "构建补丁镜像：$base_image → $target_tag"

  workdir="$(mktemp -d "${TMPDIR:-/tmp}/patch-image.XXXXXX")"
  src="$workdir/session-key.ts"
  out="$workdir/session-key.ts.new"

  # 原始属主：镜像里文件属于 app(10001)，COPY 覆盖后属主会变 root，
  # 这里先记下来，build 时还原。
  owner="$($DOCKER run --rm --user 0 --entrypoint stat "$base_image" \
    -c '%u:%g' "$PROXY_SESSION_KEY_PATH" 2>/dev/null || echo '10001:999')"
  info "原属主 uid:gid = $owner"

  # 镜像原本以哪个用户运行（一般是 app），build 时 USER 要还原成它
  image_user="$($DOCKER image inspect -f '{{.Config.User}}' "$base_image" 2>/dev/null || echo 'app')"
  [[ -n "$image_user" ]] || image_user="app"

  # 取出源文件（用 create 而不是 run，不启动业务进程）
  rm_container_if_exists "$tmp_ct"
  $DOCKER create --name "$tmp_ct" "$base_image" >/dev/null
  info "取出 $PROXY_SESSION_KEY_PATH"
  $DOCKER cp "$tmp_ct:$PROXY_SESSION_KEY_PATH" "$src"
  $DOCKER rm -f "$tmp_ct" >/dev/null

  if grep -q "\"${PROXY_NEW_HEADER}\"" "$src"; then
    ok "源文件已包含 $PROXY_NEW_HEADER，无需插入"
    cp "$src" "$out"
  else
    patch_session_key_file "$src" "$out" \
      "$base_image:$PROXY_SESSION_KEY_PATH" "$PROXY_NEW_HEADER" "$PROXY_ANCHOR_HEADER"
    info "补丁 diff："
    diff -u --label "镜像内(改前)" "$src" --label "镜像内(改后)" "$out" || true
  fi

  # 派生镜像：只多一层 COPY，ENTRYPOINT/CMD/USER 全部保持原样
  cat > "$workdir/Dockerfile" <<DOCKERFILE
# 由 start-all-patch.sh 自动生成：给 proxy 镜像打 session key 补丁。
FROM $base_image
USER root
COPY session-key.ts $PROXY_SESSION_KEY_PATH
RUN chown $owner $PROXY_SESSION_KEY_PATH
USER $image_user
DOCKERFILE
  cp "$out" "$workdir/session-key.ts"

  $DOCKER build -t "$target_tag" -f "$workdir/Dockerfile" "$workdir" >/dev/null \
    || die "构建补丁镜像 $target_tag 失败。"
  ok "已生成补丁镜像 $target_tag"

  rm -rf "$workdir"
}

# ── 启动三件套 ───────────────────────────────────────────────────────────
info "═══ Step 1/4: memory ═══════════════════════════════════════"
"$SCRIPT_DIR/start-memory-core.sh"

info "═══ Step 2/4: memory-hub ═══════════════════════════════════"
"$SCRIPT_DIR/start-memory-hub.sh"

info "═══ Step 3/4: 构建 proxy 补丁镜像 ════════════════════════════"
# PULL=1 拉的是 base 镜像；补丁镜像在本地生成，不能 pull。
if [[ "${PULL:-0}" == "1" ]]; then
  pull_image "$PROXY_IMAGE"
fi

# 补丁镜像 tag：默认 <base去掉tag>:patched-sessionkey
# 只在最后一个 '/' 之后确实存在 ':' 时才剥掉原 tag，避免把 registry:5000 误判。
if [[ -z "${PROXY_PATCHED_IMAGE:-}" ]]; then
  _img_tail="${PROXY_IMAGE##*/}"
  if [[ "$_img_tail" == *:* ]]; then
    _base_no_tag="${PROXY_IMAGE%:*}"
  else
    _base_no_tag="$PROXY_IMAGE"
  fi
  PROXY_PATCHED_IMAGE="${_base_no_tag}:patched-sessionkey"
fi

build_patched_image "$PROXY_IMAGE" "$PROXY_PATCHED_IMAGE"

info "═══ Step 4/4: proxy（用补丁镜像启动）════════════════════════"
# start-proxy.sh 从 .env 读 PROXY_IMAGE，且 PULL=1 时会去 pull 该 tag
# （补丁镜像在本地，仓库里没有）—— 所以给它一份临时 .env 副本：
# PROXY_IMAGE 换成补丁镜像，PULL 关掉。用完即删，用户的 .env 不受影响。
PROXY_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/proxy-env.XXXXXX")"
trap 'rm -f "$PROXY_ENV_FILE"' EXIT
cp "$ENV_FILE" "$PROXY_ENV_FILE"
set_env_value PROXY_IMAGE "$PROXY_PATCHED_IMAGE" "$PROXY_ENV_FILE"
# PULL 也写进副本：load_env 会 source 这个文件，用户 .env 里若有 PULL=1
# 会覆盖掉环境变量，导致去 pull 本地生成的补丁镜像（仓库里没有，拉必失败）。
set_env_value PULL 0 "$PROXY_ENV_FILE"
ENV_FILE="$PROXY_ENV_FILE" "$SCRIPT_DIR/start-proxy.sh"
rm -f "$PROXY_ENV_FILE"

ok "═══ 全部服务已就绪 ═════════════════════════════════════════"
print_endpoints

# 打印 Claude Code / proxy 使用命令
ADMIN_KEY_FILE="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"
if [[ -s "$ADMIN_KEY_FILE" ]]; then
  ADMIN_KEY=$(cat "$ADMIN_KEY_FILE")
  UPSTREAM_MODEL="${PROXY_UPSTREAM_MODEL:-<your-model>}"
  echo ""
  echo "  ┌─ 通过 proxy 用 Claude Code ─────────────────────────────────────┐"
  echo "  │  export ANTHROPIC_BASE_URL=http://127.0.0.1:${PROXY_PORT}/claude-code/default"
  echo "  │  export ANTHROPIC_AUTH_TOKEN='${ADMIN_KEY}'"
  echo "  │  claude --model ${UPSTREAM_MODEL}"
  echo "  │"
  echo "  │  admin user_key 保存在: $ADMIN_KEY_FILE"
  echo "  └────────────────────────────────────────────────────────────────┘"
fi
echo ""
echo "  proxy 镜像: $PROXY_PATCHED_IMAGE（基于 $PROXY_IMAGE 打补丁生成）"
echo "  查看日志：  docker logs -f tdai-memory-core | tdai-memory-hub | tdai-proxy"
echo "  停止服务：  ./stop-all.sh"
echo ""
