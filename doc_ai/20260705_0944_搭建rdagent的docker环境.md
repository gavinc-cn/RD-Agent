# 搭建 RD-Agent 的 Docker 环境 (Dockerfile + Compose)

- 日期: 2026-07-05
- 目标: 为 RD-Agent 提供一套开箱即用的容器化部署方案, 适配 Windows Docker Desktop(及 Linux)。

## 1. 背景与关键结论

调研仓库后得到以下关键事实, 直接决定了 Docker 方案的设计:

1. **必须能调 Docker daemon**: RD-Agent 运行时通过 `docker` Python SDK 调宿主机 docker daemon, 在宿主机上 spawn 沙箱容器执行它生成的代码。
   - `rdagent/utils/env.py:140` → `docker.APIClient(base_url="unix://var/run/docker.sock")`
   - `rdagent/utils/env.py`, `rdagent/app/utils/health_check.py`, `rdagent/app/utils/info.py` 多处 `docker.from_env()`
   - 结论: 采用 **DooD (docker-outside-of-docker)** —— 镜像内置 docker CLI, 运行时挂宿主机 `/var/run/docker.sock`。不需要 `--privileged`, 安全; 且与 Windows Docker Desktop 挂载 socket 的方式天然契合。
2. **不需要数据库**: 无 MySQL, 无强制 MLflow(MLflow 由 `ENABLE_MLFLOW` 控制, 默认关)。所有数据都是 CWD 下的本地文件。
3. **CWD 相对路径读写**: `cli.py` 启动时 `load_dotenv(".env")`; 数据落在 `./git_ignore_folder/`、`./log/`、`./pickle_cache/`、`./prompt_cache.db`。所以容器 `working_dir` 固定 `/app`, 并把这些目录 bind 出来。
4. **入口**: `rdagent` console script(`rdagent.app.cli:app`, typer)。常用子命令 `health_check` / `ui`(Streamlit, 19899) / `server_ui`(Flask, 19899) / `ds_user_interact`(19900) / `fin_factor` / `data_science` / `llm_finetune` 等。
5. **Python 3.10**(README 推荐, `requires-python>=3.10`)。
6. **版本号来自 git tag**: setuptools-scm; 构建上下文不带 `.git`, 用 `SETUPTOOLS_SCM_PRETEND_VERSION` 兜底。

## 2. 文件清单

| 文件 | 作用 |
| --- | --- |
| `docker/Dockerfile` | 应用镜像: python:3.10-slim + 系统 deps + 从 `docker:27-cli` 拷 docker CLI + 分层装依赖 + editable install |
| `docker/entrypoint.sh` | 入口: 建数据目录、检查 docker.sock、`exec "$@"` |
| `docker-compose.yml` | 编排: YAML anchor 复用配置; `ui` 服务 + `runner`/`server-ui`/`ds-interact` 三个 profile 服务 |
| `.dockerignore` | 缩小构建上下文(排除数据/缓存/`.git`/文档/前端构建产物) |
| `docker/.env.docker.example` | docker 专用 env 模板, 标注覆盖项与场景前缀 |

## 3. Dockerfile 设计

- **base**: `python:3.10-slim`(Debian Bookworm)。`ARG PYTHON_VERSION=3.10` 可改 3.11。
- **系统依赖**: `git build-essential ca-certificates procps`(轻量)。`build-essential` 留给少数无 wheel 的包。
- **docker CLI**: `COPY --from=docker:27-cli /usr/local/bin/docker ...` —— 一行拷静态二进制, 不引入 apt repo / gnupg, 镜像更干净。
- **分层缓存**: 先 `COPY requirements.txt requirements/` → `pip install -r requirements.txt`; 再 `COPY . /app` → `pip install -e . --no-deps`。源码改动不触发依赖重装。
- **可选 extras(build arg)**:
  - `INSTALL_TORCH=true`: 装 torch(finetune / data_science GPU 场景)。
  - `INSTALL_CHROMIUM=true`: 装 chromium + driver(general_model 抓论文的 selenium 用)。
- **版本兜底**: `ARG RDAGENT_VERSION=0.0.0` → `ENV SETUPTOOLS_SCM_PRETEND_VERSION`, 避免 `.git` 缺失导致 setuptools-scm 取版本失败。
- **入口**: `ENTRYPOINT [rdagent-entrypoint.sh]`, `CMD ["rdagent","health_check"]`(被 compose `command` 覆盖)。`EXPOSE 19899 19900`。

## 4. docker-compose 设计

- 用 YAML 锚点 `x-rdagent-common` 抽出公共配置(`build`/`env_file`/`volumes`/`init`/`shm_size`), 4 个服务引用, 改一处全生效。
- **volumes**:
  - `/var/run/docker.sock:/var/run/docker.sock` —— DooD 关键(Windows Docker Desktop + Linux 容器同样有效)。
  - `./git_ignore_folder` / `./log` / `./pickle_cache` bind 到 `/app` 下对应路径, 与原生安装目录布局一致, 方便在宿主机直接看产物。
  - 注释项 `./rdagent:/app/rdagent` —— 开发热改。
- **`init: true`**: tini 做 PID 1, 处理信号与僵尸进程(无需在镜像装 tini)。
- **服务划分(profile)**:
  - `ui`(默认随 `up`): `rdagent ui --port 19899 --log-dir /app/log`, 映射 19899。
  - `runner`(profile `cli`): 一次性命令, 用 `docker compose run --rm runner rdagent <子命令>`。
  - `server-ui`(profile `server-ui`): `rdagent server_ui`, 需先构建前端到 `git_ignore_folder/static`(设 `UI_STATIC_PATH`)。
  - `ds-interact`(profile `ds`): `rdagent ds_user_interact --port 19900`。
- **GPU**: 文件末尾注释给出 `deploy.resources.reservations.devices` 写法, 按需粘到对应服务。
- **`PROMPT_CACHE_PATH` 覆盖**: 显式设到 `/app/git_ignore_folder/prompt_cache.db`, 让 prompt 缓存落进 bind 挂载的数据卷, 避免在 Windows 上单文件挂载。

## 5. 使用流程(Windows Docker Desktop)

```powershell
# 0) 准备 .env
cp docker/.env.docker.example .env
# 编辑 .env, 填 CHAT_MODEL / EMBEDDING_MODEL / OPENAI_API_KEY 等

# 1) 构建镜像(首次; 注意 Git Bash 用 //var/run/... 的路径坑只影响手动 docker run, compose 不受影响)
docker compose build

# 2) 起交互式 UI, 浏览器开 http://localhost:19899
docker compose up ui

# 3) 一次性跑某个 agent loop
docker compose run --rm runner rdagent fin_factor
docker compose run --rm runner rdagent data_science --competition titanic

# 4) 自检
docker compose run --rm runner rdagent health_check
```

**server_ui 前端构建**(可选):
```powershell
cd web
npm install
npm run build:flask   # 输出到 ../git_ignore_folder/static
cd ..
docker compose --profile server-ui up server-ui
```

## 6. 注意事项 / 已知坑

- **Windows 路径转换**: 在 Git Bash 里手敲 `docker run -v /var/run/...` 会被 MSYS 改写成 `C:\...`, 需用 `//var/run/...`; **compose 不受影响**(yml 里就是单斜杠)。建议直接用 compose。
- **`.env` 必须 `.env`(非 `.env.example`)**: compose `env_file` 默认文件不存在会报错。
- **bind mount 权限**: 容器内默认 root 写, bind 出来的文件在 Windows 上是普通文件, 读写正常。
- **不要在镜像里 commit 代码**(项目规则: 禁止 `git commit/push`)。本方案只创建文件, 不提交。
- **不自行构建/编译**(项目规则): 文档仅给出构建命令, 由用户自行执行。
- **DooD 安全**: 挂载 socket = 容器拿到宿主机 docker 完全控制权。仅在可信环境/可信代码使用。

## 7. 后续可扩展

- 若要 CI 化, 可加 `docker/ci.Dockerfile` 用多阶段构建瘦身(去掉 build-essential)。
- 若需要完全隔离, 可另出一份 `docker/dind-compose.yml` 用 `docker:dind` + `--privileged`。
- MLflow 如需启用: `ENABLE_MLFLOW=true` + 可加一个 `mlflow` service。
