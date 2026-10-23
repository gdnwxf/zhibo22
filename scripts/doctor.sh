#!/usr/bin/env bash
# 本机环境自检：确认 ffmpeg 能力与依赖是否满足推流需求
set -euo pipefail

echo "=== 系统 ==="
uname -a

echo
echo "=== 依赖检查 ==="
for c in ffmpeg ffprobe curl nc; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  [OK]   $c -> $(command -v "$c")"
  else
    echo "  [MISS] $c 未安装"
  fi
done

# 容器运行时二选一即可（Podman 优先）
if command -v podman >/dev/null 2>&1; then
  echo "  [OK]   podman -> $(command -v podman) ($(podman --version 2>/dev/null | awk '{print $3}'))"
  if podman info >/dev/null 2>&1; then
    echo "         podman machine/守护进程：运行中"
  else
    echo "         [WARN] podman machine 未运行，执行：podman machine start"
  fi
elif command -v docker >/dev/null 2>&1; then
  echo "  [OK]   docker -> $(command -v docker)"
  if docker info >/dev/null 2>&1; then
    echo "         docker 守护进程：运行中"
  else
    echo "         [WARN] docker 守护进程未运行，请打开 Docker Desktop"
  fi
else
  echo "  [MISS] podman / docker 均未安装（跑 SRS 服务端需要其一）"
fi

echo
echo "=== ffmpeg 关键能力 ==="
for e in libx264 h264_videotoolbox aac; do
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $e "; then
    echo "  [OK]   编码器 $e"
  else
    echo "  [MISS] 编码器 $e"
  fi
done
if ffmpeg -hide_banner -devices 2>/dev/null | grep -qE 'avfoundation|x11grab|gdigrab'; then
  echo "  [OK]   屏幕采集输入设备可用"
  ffmpeg -hide_banner -devices 2>/dev/null | grep -E 'avfoundation|x11grab|gdigrab' | sed 's/^/         /'
else
  echo "  [MISS] 无屏幕采集设备（检查 ffmpeg 编译选项）"
fi

echo
echo "=== 提示 ==="
echo "  macOS 首次屏幕录制需授权：系统设置 → 隐私与安全 → 屏幕录制 → 勾选终端"
echo "  麦克风同理：隐私与安全 → 麦克风"
