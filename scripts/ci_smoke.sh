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

echo "[1/5] harness 上游 clone ($HARNESS_REF, 带重试)"
rm -rf harness
for i in 1 2 3; do
  if git clone --depth 1 --branch "$HARNESS_REF" https://github.com/allenai/vla-evaluation-harness.git harness; then break; fi
  echo "clone 失败, 重试 $i..."; rm -rf harness; sleep 15
  [ "$i" = "3" ] && exit 128
done

echo "[2/5] benchmark 镜像 (libero 拉取, molmo 本地构建, 上游未发布)"
docker pull "$LIBERO_IMAGE"
if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q 'vla-evaluation-harness/molmospaces:latest'; then
  (cd harness && bash docker/build.sh molmospaces)
fi
docker images | grep -E 'molmospaces|libero' || true

echo "[3/5] 构建 verify 镜像 (vla-eval + lerobot + torch, host 缓存)"
docker build -f docker/Dockerfile.verify -t "$VERIFY_IMAGE" .

echo "[4/5] 启动 pi0 serve (GPU0, 后台)"
docker rm -f pi0-serve 2>/dev/null || true
docker run -d --name pi0-serve --gpus '"device=0"' --network host \
  -v "$WORK":/work -w /work/harness \
  -e CUDA_VISIBLE_DEVICES=0 -e COMPILE_MODEL=false \
  "$VERIFY_IMAGE" \
  vla-eval serve -c configs/model_servers/lerobot/pi05_libero.yaml
echo "等待 serve 端口 8000 (checkpoint 下载可能很久, 最多 20min)"
sleep 15
if [ "$(docker inspect -f '{{.State.Running}}' pi0-serve 2>/dev/null)" != "true" ]; then
  echo "serve 容器秒退, 日志:"; docker logs pi0-serve 2>&1 | tail -n 30; docker rm -f pi0-serve; exit 1
fi
for i in $(seq 1 120); do
  if (echo > /dev/tcp/127.0.0.1/8000) 2>/dev/null; then echo "serve UP"; break; fi
  if [ "$i" = "120" ]; then echo "serve 起不来, 看日志:"; docker logs pi0-serve 2>&1 | tail -n 30; docker rm -f pi0-serve; exit 1; fi
  sleep 10
done

echo "[5/5] 跑 MolmoSpaces smoke (10ep)"
set +e
docker run --rm --gpus all --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$WORK":/work -w /work \
  -e CUDA_VISIBLE_DEVICES=0 \
  "$VERIFY_IMAGE" \
  vla-eval run --config /work/configs/run-molmo-smoke10.yaml 2>&1 | tee results/smoke.log
CODE=${PIPESTATUS[0]}
set -e
docker rm -f pi0-serve 2>/dev/null || true
ls -lh results/ || true
echo "smoke_exit=$CODE"
exit $CODE
