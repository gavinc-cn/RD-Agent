#!/bin/sh
# RD-Agent 容器入口脚本
#   1. 确保挂载进来的数据目录存在 (bind mount 只挂父目录, 子目录要自建)
#   2. 检查 docker.sock 是否挂进来 (DooD 模式必须), 缺失给友好提示
#   3. exec 透传 CMD / command
set -e

DATA_DIR="${RDAGENT_WORKDIR:-/app}"
mkdir -p "$DATA_DIR/log" \
         "$DATA_DIR/pickle_cache" \
         "$DATA_DIR/git_ignore_folder"

# ---- docker 连通性自检 -------------------------------------------
# DooD 模式下必须有宿主机 socket; 没挂上时 rdagent 一跑代码沙箱就会报错,
# 这里提前给个明确提示 (尤其 Windows Docker Desktop 容易漏挂)。
if [ ! -S /var/run/docker.sock ]; then
    echo "=============================================================="
    echo "  [警告] 没有找到 /var/run/docker.sock"
    echo "  RD-Agent 需要 docker daemon 来 spawn 代码沙箱容器。"
    echo "  请确认 docker-compose.yml 里挂载了宿主机的 docker socket:"
    echo "      volumes:"
    echo "        - /var/run/docker.sock:/var/run/docker.sock"
    echo "  (Windows Docker Desktop 下用 Linux 容器时此路径同样有效)"
    echo "=============================================================="
else
    echo "[entrypoint] docker socket 就绪: /var/run/docker.sock"
fi

# 透传给 CMD / compose 的 command (如 rdagent ui ...)
exec "$@"
