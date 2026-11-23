#!/usr/bin/env python3
"""OpenAI 兼容端点验证脚本(裸机部署步骤 7 用)。

用法(任一节点或可直达端点的机器):
    python3 verify_inference.py --base-url http://<NODE1-IP>:8000 --model glm-5.3
    python3 verify_inference.py --base-url http://<NODE1-IP>:8000 --model glm-5.3 --stream
    python3 verify_inference.py --base-url http://<NODE1-IP>:8000 --model glm-5.3 --n 8 --concurrency 4   # 简单压测
仅用标准库。PD 部署必须把 base-url 指向 Proxy 端口(默认 8000),不要直连 8100/8200 后端。
"""
import argparse
import json
import re
import sys
import threading
import time
import urllib.request

ARGS = None


def http_json(url, payload=None, timeout=300):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, json.loads(resp.read().decode())


def check_models():
    base = ARGS.base_url.rstrip("/")
    try:
        status, body = http_json(f"{base}/v1/models", timeout=15)
        ids = [m.get("id") for m in body.get("data", [])]
        print(f"[1] GET /v1/models -> {status}, models={ids}")
        if ARGS.model not in ids:
            print(f"    ⚠ 请求的 model '{ARGS.model}' 不在列表中,chat 调用将失败")
            return False
        return True
    except Exception as e:  # noqa: BLE001
        print(f"[1] GET /v1/models 失败: {e}")
        return False


def one_chat(seq=None, label=""):
    base = ARGS.base_url.rstrip("/")
    payload = {
        "model": ARGS.model,
        "messages": [{"role": "user", "content": ARGS.prompt}],
        "max_completion_tokens": ARGS.max_tokens,
        "stream": ARGS.stream,
    }
    t0 = time.time()
    try:
        if ARGS.stream:
            req = urllib.request.Request(
                f"{base}/v1/chat/completions",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            chunks, text = 0, []
            with urllib.request.urlopen(req, timeout=300) as resp:
                for raw in resp:
                    line = raw.decode().strip()
                    if not line.startswith("data:"):
                        continue
                    body = line[5:].strip()
                    if body == "[DONE]":
                        break
                    chunks += 1
                    delta = json.loads(body)["choices"][0].get("delta", {})
                    text.append(delta.get("content", ""))
            out = "".join(text)
            print(f"[2]{label} stream ok: {chunks} chunks, {time.time()-t0:.1f}s, 内容: {out[:120]}")
            return bool(out.strip())
        status, body = http_json(f"{base}/v1/chat/completions", payload)
        choice = body["choices"][0]
        content = choice.get("message", {}).get("content", "")
        reasoning = choice.get("message", {}).get("reasoning_content") or ""
        usage = body.get("usage", {})
        dt = time.time() - t0
        print(f"[2]{label} chat -> {status}, {dt:.1f}s, prompt={usage.get('prompt_tokens')}tk, "
              f"completion={usage.get('completion_tokens')}tk")
        if reasoning:
            print(f"    (reasoning {len(reasoning)} 字符,已分离)")
        print(f"    内容: {content[:200]}")
        return bool(content.strip())
    except Exception as e:  # noqa: BLE001
        print(f"[2]{label} chat 失败({time.time()-t0:.1f}s): {e}")
        return False


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", required=True, help="如 http://<NODE1-IP>:8000 (PD 填 Proxy)")
    p.add_argument("--model", required=True)
    p.add_argument("--prompt", default="请只回答:部署成功")
    p.add_argument("--max-tokens", type=int, default=64)
    p.add_argument("--stream", action="store_true")
    p.add_argument("--n", type=int, default=1, help="总请求数(>1 即简单压测)")
    p.add_argument("--concurrency", type=int, default=1)
    p.add_argument("--skip-models", action="store_true")
    ARGS = p.parse_args()

    if not re.match(r"^https?://[\w.\-]+:\d+$", ARGS.base_url):
        sys.exit(f"base-url 格式应为 http://<ip>:<port>,收到: {ARGS.base_url}")

    ok = True
    if not ARGS.skip_models:
        ok = check_models()
    if ARGS.n <= 1:
        ok = one_chat() and ok
    else:
        results, lock, idx = [], threading.Lock(), [0]

        def worker():
            with lock:
                idx[0] += 1
                my = idx[0]
            results.append(one_chat(seq=my, label=f"#{my}"))

        threads = []
        t0 = time.time()
        for _ in range(ARGS.n):
            while len(threads) - sum(r is not None and not t.is_alive() for t in threads) >= ARGS.concurrency:
                time.sleep(0.05)
            t = threading.Thread(target=worker)
            t.start()
            threads.append(t)
        for t in threads:
            t.join()
        ok = all(results) and ok
        print(f"[3] 压测: {ARGS.n} 请求 / 并发 {ARGS.concurrency}, 总耗时 {time.time()-t0:.1f}s, "
              f"成功 {sum(results)}/{ARGS.n}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
