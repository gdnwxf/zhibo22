#!/usr/bin/env python3
"""SRS on_publish 推流鉴权回调服务（第 5 节）

SRS 推流时会 POST 一个 JSON 到本服务，本服务返回：
  {"code": 0}    -> 允许推流
  {"code": 403}  -> 拒绝推流

启动：
    python3 scripts/auth_server.py
    # 默认监听 127.0.0.1:8085，校验 token=abc123

自定义：
    TOKEN=mysecret PORT=8085 python3 scripts/auth_server.py

推流地址（带 token）：
    rtmp://localhost/live/livestream?token=abc123
"""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("TOKEN", "abc123")
PORT = int(os.environ.get("PORT", "8085"))


class AuthHandler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""

        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            payload = {}

        # SRS 把推流 URL 的查询串放在 param 字段：?token=abc123
        param = payload.get("param", "") or ""
        app = payload.get("app", "")
        stream = payload.get("stream", "")
        client_ip = payload.get("ip", "")

        token_ok = f"token={TOKEN}" in param
        code = 0 if token_ok else 403

        # 保留审计记录：允许/拒绝都打印，便于排查推流失败
        print(
            f"{'ALLOW' if token_ok else 'DENY '} "
            f"app={app} stream={stream} ip={client_ip} param={param}",
            flush=True,
        )

        body = json.dumps({"code": code}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        """静音默认访问日志，只保留上面的审计行。"""
        return


if __name__ == "__main__":
    print(f"鉴权服务已启动 http://127.0.0.1:{PORT}/api/v1/publish  token={TOKEN}")
    print("SRS 回调地址写法：")
    print("  源码本机启动： on_publish http://127.0.0.1:%d/api/v1/publish;" % PORT)
    print("  容器启动：     on_publish http://host.containers.internal:%d/api/v1/publish;" % PORT)
    print("                 ^ 容器里 127.0.0.1 指向容器自身，必须用 host.containers.internal")
    ThreadingHTTPServer(("127.0.0.1", PORT), AuthHandler).serve_forever()
