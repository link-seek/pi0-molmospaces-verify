#!/bin/bash
# CI smoke: host 编排 serve(verify 容器, GPU0) + run(verify 容器, dockersock)。
# 上游 serve 配置直接用 harness 原生文件，不手写 extends。
set -e
cd "$(dirname "$0")/.."
WORK="$PWD"
HARNESS_REF="${HARNESS_REF:-v0.7.0}"
MOLMO_IMAGE="ghcr.io/allenai/vla-evaluation-harness/molmospaces:latest"
LIBERO_IMAGE="ghcr.io/allenai/vla-evaluation-harness/libero:latest"
VERIFY_IMAGE="pi0-molmo-verify:0.1"
mkdir -p results
echo "[0/5] workspace 属主修复 (容器以 root 写文件, 改回 runner 1001)"
docker run --rm -v "$WORK":/w python:3.12-slim chown -R 1001:1001 /w 2>/dev/null || \
  sudo chown -R "$(id -u):$(id -g)" "$WORK" 2>/dev/null || true

echo "[1b/5] lerobot 源码 (host 侧 clone, serve 容器内 github 不通, header 改本地 path)"
LEROBOT_URL="https://github.com/huggingface/lerobot.git"
[ -n "${GITHUB_TOKEN:-}" ] && LEROBOT_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/huggingface/lerobot.git"
if [ ! -f lerobot-src/pyproject.toml ]; then
  rm -rf lerobot-src
  for i in 1 2 3 4 5; do
    if git clone --depth 1 --branch v0.6.0 "$LEROBOT_URL" lerobot-src 2>&1 | tail -n 1; then break; fi
    echo "lerobot clone 失败, 重试 $i..."; rm -rf lerobot-src; sleep 20
    [ "$i" = "5" ] && exit 128
  done
else
  echo "lerobot-src 已存在, 跳过 clone"
fi
if [ ! -f harness/pyproject.toml ]; then
  rm -rf harness
  CLONE_URL="https://github.com/allenai/vla-evaluation-harness.git"
  [ -n "${GITHUB_TOKEN:-}" ] && CLONE_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/allenai/vla-evaluation-harness.git"
  for i in 1 2 3 4 5; do
    if git clone --depth 1 --branch "$HARNESS_REF" "$CLONE_URL" harness 2>&1 | tail -n 1; then break; fi
    echo "clone 失败, 重试 $i..."; rm -rf harness; sleep 20
    [ "$i" = "5" ] && exit 128
  done
else
  echo "harness 已存在, 跳过 clone"
fi
echo "[1c/5] harness serve 脚本 header 改本地 lerobot (容器内 github 不通)"
if ! grep -q '/work/lerobot-src' harness/src/vla_eval/model_servers/lerobot.py; then
  sed -i 's|lerobot = { git = "https://github.com/huggingface/lerobot.git", rev = "v0.6.0" }|lerobot = { path = "/work/lerobot-src" }|' harness/src/vla_eval/model_servers/lerobot.py
  grep -n 'lerobot = {' harness/src/vla_eval/model_servers/lerobot.py | head -n 2
else
  echo "header 已 patch, 跳过"
fi

echo "[2/5] benchmark 镜像 (libero 拉取, molmo 本地构建, 上游未发布)"
docker pull "$LIBERO_IMAGE"
if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q 'vla-evaluation-harness/molmospaces:latest'; then
  (cd harness && bash docker/build.sh molmospaces)
fi
docker images | grep -E 'molmospaces|libero' || true

echo "[3/5] 构建 verify 镜像 (vla-eval + lerobot + torch, host 缓存)"
docker build -f docker/Dockerfile.verify -t "$VERIFY_IMAGE" .

echo "[4/5] 预热 checkpoint 缓存 (mirror 可靠, 带重试)"
for i in 1 2 3; do
  if docker run --rm --network host \
    -v "$WORK/.cache/hf":/root/.cache/huggingface \
    -e HF_ENDPOINT=https://hf-mirror.com \
    "$VERIFY_IMAGE" python -c "from huggingface_hub import snapshot_download; snapshot_download('lerobot/pi05_libero_finetuned', max_workers=4)" 2>&1 | tail -n 2; then break; fi
  echo "checkpoint 预热失败, 重试 $i..."; sleep 15
  [ "$i" = "3" ] && exit 1
done
echo "[4/5] 启动 pi0 serve (GPU0, 后台; uv/HF 缓存持久化到 workspace)"
mkdir -p "$WORK/.cache/uv" "$WORK/.cache/hf"
docker rm -f pi0-serve 2>/dev/null || true
start_serve() {
docker run -d --name pi0-serve --gpus '"device=0"' --network host \
  -v "$WORK":/work -w /work/harness \
  -v "$WORK/.cache/uv":/root/.cache/uv \
  -v "$WORK/.cache/hf":/root/.cache/huggingface \
  -e CUDA_VISIBLE_DEVICES=0 -e COMPILE_MODEL=false \
  -e HF_ENDPOINT=https://hf-mirror.com -e HF_HUB_VERBOSITY=warning \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  "$VERIFY_IMAGE" \
  vla-eval serve -c configs/model_servers/lerobot/pi05_libero.yaml
}
wait_serve() {
  # 返回 0=UP, 1=容器退出(看日志), 2=超时
  for i in $(seq 1 120); do
    if [ "$(docker inspect -f '{{.State.Running}}' pi0-serve 2>/dev/null)" != "true" ]; then return 1; fi
    if (echo > /dev/tcp/127.0.0.1/8000) 2>/dev/null; then echo "serve UP"; return 0; fi
    if [ "$i" = "120" ]; then return 2; fi
    sleep 10
  done
}
SERVE_OK=0
for attempt in 1 2 3; do
  echo "serve 启动尝试 $attempt/3"
  docker rm -f pi0-serve 2>/dev/null || true
  start_serve
  sleep 15
  if wait_serve; then SERVE_OK=1; break; fi
  echo "serve 未起来 (尝试 $attempt), 尾日志:"; docker logs pi0-serve 2>&1 | tail -n 15
  docker rm -f pi0-serve 2>/dev/null || true
  sleep 10
done
[ "$SERVE_OK" = "1" ] || { echo "serve 3次都起不来"; exit 1; }

echo "[5/5] 跑 MolmoSpaces smoke (10ep, 用 molmo 镜像自带 env,当 client)"
set +e
docker run --rm --gpus all --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$WORK":/work -w /work \
  -v "$WORK/.cache/hf":/root/.cache/huggingface \
  -e CUDA_VISIBLE_DEVICES=0 \
  "$MOLMO_IMAGE" \
  run --config /work/configs/run-molmo-smoke10.yaml 2>&1 | tee results/smoke.log
CODE=${PIPESTATUS[0]}
set -e
docker rm -f pi0-serve 2>/dev/null || true
ls -lh results/ || true
echo "smoke_exit=$CODE"
exit $CODE
