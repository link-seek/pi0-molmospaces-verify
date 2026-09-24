# pi0-molmospaces-verify

用 `vla-evaluation-harness` 验证 `pi0`（`lerobot/pi05_libero_finetuned`）能否按 `MolmoSpaces` 评分标准出分。轻量 smoke 优先。

上游：https://github.com/allenai/vla-evaluation-harness（`v0.7.0`，`vla-eval` 包名）

## Pin

- `vla-eval`: `v0.7.0`
- `lerobot`: `v0.6.0`
- benchmark 镜像：`ghcr.io/allenai/vla-evaluation-harness/molmospaces:latest`
- checkpoint：`lerobot/pi05_libero_finetuned`（`policy_type: pi05`）

## 结论前置（已确认）

- LIBERO 通不代表 MolmoSpaces 通：仿真后端、动作口径（`joint_pos absolute + clamp + 15Hz + horizon 600`）、观测映射都不同，需单独跑 smoke。
- MolmoSpaces 是单臂 `Franka FR3`，比 RoboTwin 双臂 14 维更对 pi0 口径，但仍需验证动作映射。

## Docker 方式运行（本项目强制要求）

```bash
# 1. 拉基准镜像
docker pull ghcr.io/allenai/vla-evaluation-harness/molmospaces:latest

# 2. 起验证环境（含 vla-eval v0.7.0）
docker build -f docker/Dockerfile.verify -t pi0-molmo-verify:0.1 .
docker run --gpus all -it --network host -v $PWD:/work -w /work pi0-molmo-verify:0.1 bash

# 3. smoke（容器内，另开两终端）
bash scripts/run_smoke.sh
```

详见 `configs/` 和 `scripts/run_smoke.sh` 注释。
