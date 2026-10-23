#!/usr/bin/env bash
# SRS 一键启动（第 1 节）
#
# 用法：
#   ./scripts/start_srs.sh            # 容器启动（自动选 podman，其次 docker）
#   ./scripts/start_srs.sh podman     # 强制用 podman
#   ./scripts/start_srs.sh docker     # 强制用 docker
#   ./scripts/start_srs.sh source     # 源码编译方式启动（需先 build）
#   ./scripts/start_srs.sh stop       # 停止容器
#
# 环境变量：
#   SRS_IMAGE  覆盖镜像地址
#   CONTAINER  容器名，默认 srs
#   LOW_LATENCY=1  挂载 conf/realtime.conf 启用低延迟配置（仅 podman/docker 方式）
set -euo pipefail

SRS_IMAGE="${SRS_IMAGE:-registry.cn-hangzhou.aliyuncs.com/ossrs/srs:5}"
CONTAINER="${CONTAINER:-srs}"
LOW_LATENCY="${LOW_LATENCY:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- 选择容器运行时：podman 优先 ----------
detect_runtime() {
  if command -v podman >/dev/null 2>&1; then
    echo podman
  elif command -v docker >/dev/null 2>&1; then
    echo docker
  else
    echo ""
  fi
}

MODE="${1:-auto}"
case "$MODE" in  stop)
    for rt in podman docker; do
      if command -v "$rt" >/dev/null 2>&1; then
        if "$rt" rm -f "$CONTAINER" >/dev/null 2>&1; then
          echo "已停止容器 ${CONTAINER}（${rt}）"
          exit 0
        fi
      fi
    done
    echo "容器 $CONTAINER 未运行"
    exit 0
    ;;
  source)
    if [[ ! -x "$PROJECT_DIR/objs/srs" ]]; then
      echo "错误: 找不到 ./objs/srs，请先编译：" >&2
      echo "  ./configure && make -j\$(nproc)" >&2
      exit 1
    fi
    CONF="${SRS_CONF:-conf/rtmp.conf}"
    echo ">> 用 $CONF 启动 SRS（Ctrl+C 停止）"
    cd "$PROJECT_DIR"
    exec ./objs/srs -c "$CONF"
    ;;
  auto|podman|docker)
    # 用 MODE 保存已做过默认值展开的入参，避免 set -u 下直接引用空 $1
    if [[ "$MODE" == "podman" || "$MODE" == "docker" ]]; then
      RUNTIME="$MODE"
    else
      RUNTIME="$(detect_runtime)"
    fi
    ;;
  *)
    echo "用法: $0 [auto|podman|docker|source|stop]" >&2
    exit 1
    ;;
esac

if [[ -z "$RUNTIME" ]]; then
  echo "错误: 未检测到 podman 或 docker。" >&2
  echo "  macOS 安装 Podman：brew install podman && podman machine init && podman machine start" >&2
  echo "  macOS 安装 Docker：brew install --cask docker  然后打开 Docker Desktop" >&2
  echo "  或改用源码方式：$0 source" >&2
  exit 1
fi

if ! "$RUNTIME" info >/dev/null 2>&1; then
  echo "错误: $RUNTIME 守护进程/虚拟机未运行。" >&2
  if [[ "$RUNTIME" == "podman" ]]; then
    echo "  执行：podman machine start" >&2
  else
    echo "  打开 Docker Desktop 后重试" >&2
  fi
  exit 1
fi

# 已有同名容器先清掉，避免端口冲突
"$RUNTIME" rm -f "$CONTAINER" >/dev/null 2>&1 || true

# 指定运行时需要显式声明镜像来源（docker.io / 阿里云等）
echo ">> 使用运行时: $RUNTIME"
echo ">> 启动 SRS 容器 ${CONTAINER}（镜像 ${SRS_IMAGE}）"
echo "   1935 RTMP | 1985 API | 8080 控制台"

RUN_ARGS=("$RUNTIME" run --rm -it --name "$CONTAINER"
  -p 1935:1935 -p 1985:1985 -p 8080:8080)

# 低延迟：把宿主机配置挂进容器，覆盖镜像默认入口 docker.conf
# （镜像 CMD 是 `./objs/srs -c conf/docker.conf`，所以必须盖这个路径才生效）
if [[ "$LOW_LATENCY" == "1" ]]; then
  echo "   低延迟模式：挂载 conf/realtime.conf -> /usr/local/srs/conf/docker.conf"
  RUN_ARGS+=(-v "$PROJECT_DIR/conf/realtime.conf:/usr/local/srs/conf/docker.conf:ro")
fi

# Ctrl+C 时确保容器被清理（podman/docker 前台运行后信号传递行为不完全一致）
cleanup() {
  "$RUNTIME" rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

exec "${RUN_ARGS[@]}" "$SRS_IMAGE"
