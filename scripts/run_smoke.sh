#!/bin/bash
set -e
# 需在已进 docker 验证容器后执行，另开双终端。
# Terminal 1: vla-eval serve -c configs/serve-pi05.yaml（等 /health 200）
# Terminal 2: 本脚本

echo "[1/3] benchmark 镜像 (molmo 上游未发布, 本地构建; libero 公开可拉)"
docker pull ghcr.io/allenai/vla-evaluation-harness/libero:latest
if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q 'vla-evaluation-harness/molmospaces:latest'; then
  echo "molmo 镜像不存在, 先 clone harness 并构建: git clone --branch v0.7.0 https://github.com/allenai/vla-evaluation-harness.git && (cd vla-evaluation-harness && bash docker/build.sh molmospaces)"
  exit 1
fi

echo "[2/3] LIBERO smoke（对照组）"
vla-eval run --config configs/run-libero-smoke.yaml || true
ls -lh results/ || true

echo "[3/3] MolmoSpaces smoke（先抽 10ep，手动 Ctrl-C 即停，确认能出 mean_success 再开全量）"
vla-eval run --config configs/run-molmo-smoke10.yaml || true
ls -lh results/ || true
echo "done. Check results/*.json mean_success."
