# RTMP 推流到 SRS 完整实操

从零跑通 `编码器 (OBS/FFmpeg) → RTMP(1935) → SRS → RTMP/HTTP-FLV/HLS/WebRTC 播放端`。

## 目录结构

```
zhibo/
├── conf/
│   ├── rtmp.conf          # 最简 RTMP 配置（源码编译启动用）
│   ├── rtmp.auth.conf     # 开启 publish 鉴权（on_publish 回调）
│   └── realtime.conf      # 低延迟配置（tcp_nodelay + min_latency）
├── scripts/
│   ├── doctor.sh          # 环境自检
│   ├── start_srs.sh       # 启动 SRS（Docker / 源码 / 停止）
│   ├── push_file.sh       # 视频文件循环推流（自动判断是否需要转码）
│   ├── push_screen.sh     # 屏幕采集 + 麦克风推流（macOS/Linux/Windows）
│   ├── auth_server.py     # on_publish 推流鉴权回调服务
│   └── verify.sh          # 拉流验证 / SRS 状态检查
└── README.md
```

## 0. 先做环境自检

```bash
./scripts/doctor.sh
```

> macOS 首次使用屏幕采集必须先授权：**系统设置 → 隐私与安全 → 屏幕录制 / 麦克风**，勾选你的终端。

## 1. 启动 SRS

脚本会自动选择容器运行时：**Podman 优先**，没有 Podman 才用 Docker。

### Podman / Docker（推荐）

```bash
./scripts/start_srs.sh            # 自动选运行时
./scripts/start_srs.sh podman     # 强制 podman
./scripts/start_srs.sh docker     # 强制 docker
./scripts/start_srs.sh stop       # 停止
```

等价的 Podman 命令：

```bash
podman machine start              # 确保虚拟机在跑
podman run --rm -it -p 1935:1935 -p 1985:1985 -p 8080:8080 \
  registry.cn-hangzhou.aliyuncs.com/ossrs/srs:5
```

等价的 Docker 命令：

```bash
docker run --rm -it -p 1935:1935 -p 1985:1985 -p 8080:8080 \
  registry.cn-hangzhou.aliyuncs.com/ossrs/srs:5
```

端口：`1935` RTMP 推流 | `1985` 后台 API | `8080` 网页控制台 | `8000/udp` WebRTC

镜像默认入口是 `conf/docker.conf`，已内含 HLS / HTTP-FLV / WebRTC 分发。

### 源码编译（Linux）

```bash
./configure && make -j$(nproc)
./scripts/start_srs.sh source                 # 用 conf/rtmp.conf
SRS_CONF=conf/realtime.conf ./scripts/start_srs.sh source   # 低延迟
```

### 低延迟模式

```bash
LOW_LATENCY=1 ./scripts/start_srs.sh
```

它把 `conf/realtime.conf` 挂载覆盖容器内的 `/usr/local/srs/conf/docker.conf`，开启 `tcp_nodelay` + `min_latency`。

## 2. 推流

地址格式：`rtmp://SRS_IP/live/streamKey`，本机即 `rtmp://localhost/live/livestream`。

### 方式 A：FFmpeg 推本地视频文件

```bash
./scripts/push_file.sh test.mp4
```

脚本会自动 ffprobe 探测编码：H.264+AAC 走 `-c copy` 零转码，否则自动切 `libx264 + aac`。

手动命令对照：

```bash
# 零转码（要求源是 H.264 + AAC）
ffmpeg -re -i test.mp4 -c copy -f flv rtmp://localhost/live/livestream

# 软转码（编码不兼容时）
ffmpeg -re -i test.mp4 -c:v libx264 -c:a aac -f flv rtmp://localhost/live/livestream
```

- `-re`：按原始帧率慢速读取，**不加会瞬间推完**
- `-c copy`：不转码，性能最高
- `-f flv`：RTMP 强制封装

### 方式 B：FFmpeg 屏幕采集 + 麦克风（你问的那个）

```bash
# 先看设备列表
./scripts/push_screen.sh list

# 直接推流
./scripts/push_screen.sh

# 指定分辨率、帧率
./scripts/push_screen.sh 1920x1080 30

# 硬编 + 自定义地址 + 鉴权 token
ENCODER=vt RTMP_URL=rtmp://192.168.1.10/live/mystream TOKEN=abc123 ./scripts/push_screen.sh
```

脚本按平台自动选择采集方式：

| 平台 | 屏幕 | 音频 | 默认编码器 |
|---|---|---|---|
| macOS | `avfoundation`（需授权） | `avfoundation` | `h264_videotoolbox` 硬编 |
| Linux | `x11grab`（Xorg） | `pulse` | `libx264` |
| Windows | `gdigrab` | `dshow` | `libx264` |

macOS 手动命令对照（屏幕索引 1 + 音频索引 0）：

```bash
ffmpeg -f avfoundation -framerate 30 -pixel_format uyvy422 \
  -capture_cursor 1 -i "1:0" \
  -c:v h264_videotoolbox -b:v 3000k -pix_fmt yuv420p \
  -c:a aac -ar 44100 -b:a 128k \
  -f flv rtmp://localhost/live/livestream
```

### 方式 C：OBS

设置 → 直播：服务器 `rtmp://127.0.0.1/live`，推流密钥 `livestream`，点开始直播。

## 3. 拉流验证

```bash
./scripts/verify.sh          # 端口 + API + 在线流 + 拉流探测
./scripts/verify.sh play     # ffplay 播放 RTMP
./scripts/verify.sh flv      # ffplay 播放 HTTP-FLV
```

其他播放地址：

- RTMP：`rtmp://localhost/live/livestream`（VLC 打开网络串流）
- HTTP-FLV：`http://localhost:8080/live/livestream.flv`
- 控制台：`http://localhost:8080/`

SRS 自带播放页：`http://localhost:8080/players/srs_player.html?stream=livestream`

## 4. 常见坑

1. **端口不通**：云服务器放行 1935 端口（另需 1985/8080）；本地防火墙别拦 1935
2. **编码报错**：RTMP 只吃 H.264 + AAC。H.265/HEVC 原生 RTMP 不支持，必须转码
3. **推流失败**：看 SRS 日志确认连接；跨局域网不要填 127.0.0.1，要填局域网 IP
4. **低延迟**：用 `LOW_LATENCY=1 ./scripts/start_srs.sh`，开启 `tcp_nodelay` 可压到几百 ms
5. **macOS 黑屏**：99% 是没授权屏幕录制，去隐私设置勾选终端后**重启终端**
6. **分辨率报错**：yuv420p 要求宽高为偶数，脚本已加 `scale=trunc(iw/2)*2:trunc(ih/2)*2`

### Podman 特有坑（已实测）

7. **Podman 虚拟机未启动**：报 `Cannot connect to Podman socket`。执行 `podman machine start`
8. **Podman 后端端口在容器内不可访问宿主机**：回调用 `127.0.0.1` 会指向容器自身，
   必须用 `host.containers.internal`（`conf/rtmp.auth.conf` 已配好）
9. **Podman 提示 "The input device is not a TTY"**：仅是无 TTY 场景下的警告，不影响运行

## 5. 鉴权推流

SRS 5 的推流鉴权走 `on_publish` HTTP 回调，没有配置里写死 token 的开关。

两个易错点（都已实测踩过）：

- `on_publish` **必须放在 `vhost → http_hooks` 里**，放到 `publish` 里 SRS 会报
  `ConfigInvalid: illegal vhost.publish.on_publish` 并直接启动失败
- 容器运行时回调地址**不能用 `127.0.0.1`**（那是容器自己），要用 `host.containers.internal`

```bash
# 终端 1：起鉴权服务（默认校验 token=abc123）
python3 scripts/auth_server.py

# 终端 2：用鉴权配置启动 SRS（Podman 示例）
podman run --rm -it --name srs -p 1935:1935 -p 1985:1985 -p 8080:8080 \
  -v "$PWD/conf/rtmp.auth.conf:/usr/local/srs/conf/docker.conf:ro" \
  registry.cn-hangzhou.aliyuncs.com/ossrs/srs:5

# 终端 3：带 token 推流
TOKEN=abc123 ./scripts/push_screen.sh

# 或者直接用 ffmpeg
ffmpeg -re -i test.mp4 -c copy -f flv \
  "rtmp://localhost/live/livestream?token=abc123"
```

自定义密钥：`TOKEN=mysecret python3 scripts/auth_server.py`。服务会打印 `ALLOW` / `DENY` 审计日志。

实测行为：错误 token 推流时 ffmpeg 报 `Input/output error`，SRS 在线流列表为空；正确 token 才建立流。

## 架构

```
编码器 (OBS/FFmpeg)
        │  RTMP 1935
        ▼
    SRS 服务
        ├── RTMP       rtmp://host/live/stream
        ├── HTTP-FLV   http://host:8080/live/stream.flv
        ├── HLS        http://host:8080/live/stream.m3u8
        └── WebRTC     低延迟播放
```
