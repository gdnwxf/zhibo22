#!/usr/bin/env bash
# 拉流验证 / SRS 状态检查（第 3 节）
#
# 用法：
#   ./scripts/verify.sh            # 全面检查：端口 + API + 流列表 + 拉流探测
#   ./scripts/verify.sh play       # 直接用 ffplay/VLC 播放 RTMP
#   ./scripts/verify.sh flv        # 播放 HTTP-FLV
set -euo pipefail

HOST="${SRS_HOST:-localhost}"
APP="${SRS_APP:-live}"
STREAM="${SRS_STREAM:-livestream}"
RTMP="rtmp://${HOST}/${APP}/${STREAM}"
FLV="http://${HOST}:8080/${APP}/${STREAM}.flv"
# SRS 的 /api/v1/streams 无尾斜杠会 301 重定向到带斜杠版本，必须带尾斜杠
API="http://${HOST}:1985/api/v1/streams/"

case "${1:-check}" in
  play)
    echo "播放 RTMP: $RTMP"
    exec ffplay -fflags nobuffer -flags low_delay -i "$RTMP"
    ;;
  flv)
    echo "播放 HTTP-FLV: $FLV"
    exec ffplay -fflags nobuffer -flags low_delay -i "$FLV"
    ;;
  hls)
    echo "HLS 地址（需 SRS 开启 hls）：http://${HOST}:8080/${APP}/${STREAM}.m3u8"
    open "http://${HOST}:8080/${APP}/${STREAM}.m3u8" 2>/dev/null || true
    exit 0
    ;;
  check) ;;
  *)
    echo "用法: $0 [check|play|flv|hls]" >&2
    exit 1
    ;;
esac

fail=0

echo "=== 1. 端口探测 ==="
for p in 1935 1985 8080; do
  if nc -z -G 2 "$HOST" "$p" 2>/dev/null; then
    echo "  [OK]   $HOST:$p 可达"
  else
    echo "  [FAIL] $HOST:$p 不可达（检查 SRS 是否启动 / 防火墙是否放行）"
    fail=1
  fi
done

echo
echo "=== 2. SRS HTTP API ==="
# 用 --fail 让 HTTP 4xx/5xx 也返回非零；再显式判断退出码与内容，避免 curl 静默成功误报 OK
if versions="$(curl -sS --fail --max-time 5 "http://${HOST}:1985/api/v1/versions" 2>/dev/null)" && [[ -n "$versions" ]]; then
  echo "  [OK]   API 正常: $(printf '%s' "$versions" | head -c 200)"
else
  echo "  [FAIL] API 无响应"
  fail=1
fi

echo
echo "=== 3. 当前在线流 ==="
streams="$(curl -sS --fail --max-time 5 "$API" 2>/dev/null || echo '')"
if [[ -z "$streams" ]]; then
  echo "  [WARN] 拿不到流列表"
else
  echo "$streams" | python3 -c '
import json, sys

# SRS /api/v1/streams 会带尾部斜杠重定向，这里只处理 JSON 主体
try:
    d = json.load(sys.stdin)
except Exception:
    print("  [WARN] 返回非 JSON")
    sys.exit(0)

ss = d.get("streams") or []
if not ss:
    print("  [WARN] 当前无推流（先跑 scripts/push_screen.sh 或 push_file.sh）")

# 避免 f-string 内嵌套引号转义（Python < 3.12 不支持），改为先取值再格式化
for s in ss:
    name = s.get("name")
    clients = s.get("clients")
    vcodec = (s.get("video") or {}).get("codec")
    acodec = (s.get("audio") or {}).get("codec")
    print("  [LIVE] %s  clients=%s  video=%s  audio=%s" % (name, clients, vcodec, acodec))
'
fi

echo
echo "=== 4. 拉流探测（探测 RTMP 流信息）==="
# 注意：不能直接 `ffprobe ... | head`，管道退出码取自 head 恒为 0，会误报 OK
if probe="$(ffprobe -v error -rtmp_live live -analyzeduration 3000000 -i "$RTMP" \
     -show_entries stream=codec_name,width,height -of default=nw=1 2>/dev/null)" && [[ -n "$probe" ]]; then
  printf '%s\n' "$probe" | sed 's/^/         /'
  echo "  [OK]   RTMP 流可拉取"
else
  echo "  [FAIL] RTMP 流拉取失败（可能还没推流）"
  fail=1
fi

echo
if [[ "$fail" == "0" ]]; then
  echo "全部检查通过 ✅"
else
  echo "存在失败项 ❌ 请对照第 4 节常见坑排查"
  exit 1
fi
