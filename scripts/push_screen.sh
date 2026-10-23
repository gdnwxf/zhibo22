#!/usr/bin/env bash
# FFmpeg 屏幕采集 + 麦克风，直接 RTMP 推到 SRS
#
# 用法：
#   ./scripts/push_screen.sh                 # 推屏幕(含系统声/设备默认) + 麦克风
#   ./scripts/push_screen.sh list            # 列出可用采集设备（macOS/Windows）
#   ./scripts/push_screen.sh 1920x1080 30    # 指定分辨率与帧率
#
# 环境变量：
#   RTMP_URL    推流地址，默认 rtmp://localhost/live/livestream
#   TOKEN       鉴权 token（开启 on_publish 时追加到 URL）
#   DISPLAY_NUM macOS 屏幕索引，默认 1（list 查看）
#   AUDIO_IDX   macOS 音频输入索引，默认自动取第一个音频设备
#   MIC_DEV     Linux 麦克风设备，默认 default
#   ENCODER     编码器：auto | x264 | vt（macOS 硬编），默认 auto
set -euo pipefail

RTMP_URL_BASE="${RTMP_URL:-rtmp://localhost/live/livestream}"
TOKEN="${TOKEN:-}"
ENCODER="${ENCODER:-auto}"
# 注意：DISPLAY_NUM 留空时按设备名自动探测屏幕索引（macOS 上 screen 常不是 1）
DISPLAY_NUM="${DISPLAY_NUM:-}"
# 是否由用户显式指定了屏幕索引
DISPLAY_NUM_SET="${DISPLAY_NUM:+1}"
# 未指定时给一个兜底值，探测失败就用它
[[ -z "$DISPLAY_NUM" ]] && DISPLAY_NUM=1
AUDIO_IDX="${AUDIO_IDX:-}"
MIC_DEV="${MIC_DEV:-default}"

# 拼鉴权参数
if [[ -n "$TOKEN" ]]; then
  if [[ "$RTMP_URL_BASE" == *"?"* ]]; then
    RTMP_URL="${RTMP_URL_BASE}&token=${TOKEN}"
  else
    RTMP_URL="${RTMP_URL_BASE}?token=${TOKEN}"
  fi
else
  RTMP_URL="$RTMP_URL_BASE"
fi

OS="$(uname -s)"

# ---------- 设备列表 ----------
if [[ "${1:-}" == "list" ]]; then
  case "$OS" in
    Darwin)
      echo "== avfoundation 设备（屏幕在 Video 列表，麦克风在 Audio 列表）=="
      ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | grep -v "^$" || true
      ;;
    Linux)
      echo "== x11grab 屏幕 =="; echo "  直接用 :0.0"
      echo "== pulse 音频源 =="; pactl list short sources 2>/dev/null || echo "  pactl 不可用，试 MIC_DEV=default"
      ;;
    *)
      echo "== dshow 设备 =="
      ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | grep -v "^$" || true
      ;;
  esac
  exit 0
fi

RES="${1:-1920x1080}"
FPS="${2:-30}"

# ---------- 屏幕采集参数 ----------
case "$OS" in
  Darwin)
    # macOS 必须走 avfoundation；屏幕需在 系统设置→隐私与安全→屏幕录制 授权终端
    # 某些机器上屏幕不是索引 1（如 MacBook 前置/桌上视角相机占据 0/1，屏幕是 2），
    # 所以自动在设备列表里找名字含 "screen" 的项，而不是硬编码默认值。
    dev_dump="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true)"
    if [[ -z "$DISPLAY_NUM_SET" ]]; then
      auto_screen="$(printf '%s\n' "$dev_dump" \
        | sed -n '/AVFoundation video devices:/,/AVFoundation audio devices:/p' \
        | grep -iE 'screen' \
        | grep -oE '\[[0-9]+\]' | head -1 | tr -d '[]' || true)"
      if [[ -n "$auto_screen" ]]; then
        DISPLAY_NUM="$auto_screen"
      fi
    fi
    if [[ -z "$AUDIO_IDX" ]]; then
      # 自动选中第一个音频设备索引
      AUDIO_IDX="$(printf '%s\n' "$dev_dump" \
        | sed -n '/AVFoundation audio devices:/,$p' \
        | grep -oE '\[[0-9]+\]' | head -1 | tr -d '[]' || true)"
      AUDIO_IDX="${AUDIO_IDX:-0}"
    fi
    VIDEO_IN=(-f avfoundation -framerate "$FPS" -pixel_format uyvy422
              -capture_cursor 1 -capture_mouse_clicks 1
              -i "${DISPLAY_NUM}:${AUDIO_IDX}")
    DEV_DESC="屏幕[$DISPLAY_NUM] + 麦克风[$AUDIO_IDX]"
    ;;
  Linux)
    # 需要 X11；Wayland 下 ffmpeg x11grab 可能取不到画面，需切到 Xorg 或用 pipewire
    VIDEO_IN=(-f x11grab -framerate "$FPS" -video_size "$RES" -i "${DISPLAY:-:0.0}"
              -f pulse -i "$MIC_DEV")
    ;;
  *)
    # Windows：gdigrab 抓屏 + dshow 麦克风；MIC_NAME 需按 list 结果填写
    MIC_NAME="${MIC_NAME:-Microphone}"
    VIDEO_IN=(-f gdigrab -framerate "$FPS" -draw_mouse 1 -video_size "$RES" -i desktop
              -f dshow -i "audio=${MIC_NAME}")
    ;;
esac

# ---------- 编码器选择 ----------
case "$ENCODER" in
  vt)   VENC=(-c:v h264_videotoolbox -b:v 3000k -realtime 1) ;;
  x264) VENC=(-c:v libx264 -preset veryfast -tune zerolatency -b:v 3000k) ;;
  auto)
    if [[ "$OS" == "Darwin" ]]; then
      VENC=(-c:v h264_videotoolbox -b:v 3000k -realtime 1)
    else
      VENC=(-c:v libx264 -preset veryfast -tune zerolatency -b:v 3000k)
    fi
    ;;
  *) echo "未知 ENCODER: ${ENCODER}（可选 auto|x264|vt）" >&2; exit 1 ;;
esac

# 奇数分辨率会让 yuv420p 编码失败，强制偶数
VENC+=(-vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -pix_fmt yuv420p -g $((${FPS}*2)))

echo "系统     : $OS"
echo "采集设备 : ${DEV_DESC:-默认}"
echo "分辨率   : $RES @ ${FPS}fps"
echo "编码器   : $ENCODER"
echo "推流地址 : $RTMP_URL"
echo ">> 按 Ctrl+C 停止推流"
echo

# 低延迟关键：-fflags nobuffer + zerolatency；-f flv 是 RTMP 强制封装
exec ffmpeg -hide_banner -loglevel warning \
  "${VIDEO_IN[@]}" \
  "${VENC[@]}" \
  -c:a aac -ar 44100 -b:a 128k -ac 2 \
  -f flv "$RTMP_URL"
