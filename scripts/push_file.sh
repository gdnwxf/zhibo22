#!/usr/bin/env bash
# FFmpeg 本地视频文件循环推流到 SRS（第 2 节 方案 A）
#
# 用法：
#   ./scripts/push_file.sh test.mp4
#   ./scripts/push_file.sh test.mp4 rtmp://192.168.1.10/live/mystream
#
# 环境变量：
#   RTMP_URL  覆盖推流地址（默认 rtmp://localhost/live/livestream）
#   TRANSCODE 1 = 强制软转码（源不是 H.264+AAC 时用）
set -euo pipefail

IN_FILE="${1:-}"
RTMP_URL="${2:-${RTMP_URL:-rtmp://localhost/live/livestream}}"
TRANSCODE="${TRANSCODE:-0}"

if [[ -z "$IN_FILE" ]]; then
  echo "用法: $0 <视频文件> [rtmp地址]" >&2
  exit 1
fi
if [[ ! -f "$IN_FILE" ]]; then
  echo "错误: 找不到文件 $IN_FILE" >&2
  exit 1
fi

# 探测源编码，决定能否 -c copy
VCODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
  -of default=nw=1:nk=1 "$IN_FILE" 2>/dev/null || echo unknown)"
ACODEC="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
  -of default=nw=1:nk=1 "$IN_FILE" 2>/dev/null || echo none)"

echo "输入文件 : $IN_FILE"
echo "视频编码 : $VCODEC"
echo "音频编码 : $ACODEC"
echo "推流地址 : $RTMP_URL"
echo

# RTMP 只吃 H.264 + AAC；不满足必须转码，否则会推流失败或黑屏
need_transcode=0
[[ "$VCODEC" != "h264" ]] && need_transcode=1
if [[ "$ACODEC" != "none" && "$ACODEC" != "aac" ]]; then
  need_transcode=1
fi
[[ "$TRANSCODE" == "1" ]] && need_transcode=1

# -re 必须加：按原始帧率慢速读取，否则会瞬间推完
if [[ "$need_transcode" == "1" ]]; then
  echo ">> 源编码不兼容 RTMP，使用软转码 (libx264 + aac)"
  exec ffmpeg -re -i "$IN_FILE" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -c:a aac -ar 44100 -b:a 128k \
    -f flv "$RTMP_URL"
else
  echo ">> 源编码兼容，直接 -c copy（零转码，性能最高）"
  exec ffmpeg -re -i "$IN_FILE" -c copy -f flv "$RTMP_URL"
fi
