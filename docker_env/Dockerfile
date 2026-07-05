# syntax=docker/dockerfile:1.7
####################################################################
# RD-Agent 应用镜像
# ------------------------------------------------------------------
# 设计要点 (DooD / docker-outside-of-docker 模式):
#   RD-Agent 运行时通过 docker SDK (docker.from_env()) 直连 docker
#   daemon, 在宿主机上 spawn 沙箱容器来执行它生成的代码
#   (见 rdagent/utils/env.py:140 -> unix://var/run/docker.sock)。
#   因此本镜像只内置 docker CLI, 真正的 daemon 复用宿主机,
#   通过 docker-compose 把 /var/run/docker.sock 挂进来即可。
#   这样既不需要 --privileged (安全), 也和你在 Windows Docker
#   Desktop 上挂载 socket 的方式天然契合。
####################################################################
ARG PYTHON_VERSION=3.10

FROM python:${PYTHON_VERSION}-slim AS base

# ---- 基础环境变量 -------------------------------------------------
# PYTHONDONTWRITEBYTECODE / PYTHONUNBUFFERED: 关掉 .pyc, 实时刷日志
# BACKEND: RD-Agent 默认走 LiteLLM (可在 .env 覆盖)
# PROMPT_CACHE_PATH: 把 prompt 缓存放到挂载的数据卷里, 避免
#                    Windows 上单文件挂载的麻烦
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive \
    BACKEND=rdagent.oai.backend.LiteLLMAPIBackend \
    PROMPT_CACHE_PATH=/app/git_ignore_folder/prompt_cache.db

# setuptools-scm 默认从 git tag 取版本号; 构建上下文里没带 .git
# (见 .dockerignore), 这里用 PRETEND_VERSION 兜底, 避免构建失败。
ARG RDAGENT_VERSION=0.0.0
ENV SETUPTOOLS_SCM_PRETEND_VERSION=${RDAGENT_VERSION}

# ---- 系统依赖 -----------------------------------------------------
#   git            : 部分 wheel / 工具链需要
#   build-essential: 少数无 wheel 的 Python 包需要本地编译
#   ca-certificates: pip / git 走 https
#   procps         : 容器内 ps/top, 排障用
#   docker CLI 直接从官方 docker:cli 镜像拷静态二进制 (DooD)
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        build-essential \
        ca-certificates \
        procps \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=docker:27-cli /usr/local/bin/docker /usr/local/bin/docker

WORKDIR /app

# ---- 第一层: 只装 Python 依赖 (最大化利用 layer 缓存) -------------
# 先单独拷依赖清单, 源码改动不会让这层失效。
COPY requirements.txt ./
COPY requirements ./requirements
RUN pip install --upgrade pip setuptools wheel \
    && pip install -r requirements.txt

# ---- 第二层: 拷源码并 editable 安装 (--no-deps 避免重复解析) ------
COPY ../docker /app
RUN pip install -e . --no-deps

# ---- 可选: torch (finetune / data_science 等 GPU 场景) -------------
# 默认不开, 减小体积; 需要时构建参数传 INSTALL_TORCH=true
ARG INSTALL_TORCH=false
RUN if [ "$INSTALL_TORCH" = "true" ]; then \
        pip install torch; \
    fi

# ---- 可选: chromium (general_model 抓论文用 selenium) -------------
# 默认不开; 需要时构建参数传 INSTALL_CHROMIUM=true
ARG INSTALL_CHROMIUM=false
RUN if [ "$INSTALL_CHROMIUM" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            chromium chromium-driver fonts-liberation \
        && apt-get clean && rm -rf /var/lib/apt/lists/* \
        && ln -sf /usr/bin/chromium /usr/bin/chrome; \
    fi

# 拷入口脚本 (放到 /app 之外, 避免开发时把源码挂进来被覆盖)
COPY docker/entrypoint.sh /usr/local/bin/rdagent-entrypoint.sh
RUN chmod +x /usr/local/bin/rdagent-entrypoint.sh

# 运行期会写入的数据目录 (bind mount 会覆盖, 这里只是兜底)
RUN mkdir -p /app/log /app/pickle_cache /app/git_ignore_folder

# ui / server_ui 用 19899, ds_user_interact 用 19900
EXPOSE 19899 19900

ENTRYPOINT ["/usr/local/bin/rdagent-entrypoint.sh"]
# 默认命令: 健康检查; 实际通过 docker-compose 的 command 覆盖
CMD ["rdagent", "health_check"]
