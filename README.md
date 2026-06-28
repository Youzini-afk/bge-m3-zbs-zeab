# BGE M3 Zeabur CPU 部署

这是一个面向 Zeabur + Docker 的 CPU-only 向量模型和重排模型部署项目。默认使用 `BAAI/bge-m3` 提供 embedding 服务，同时部署 `BAAI/bge-reranker-base` 和 `BAAI/bge-reranker-v2-m3` 两个 rerank 服务，并通过统一网关按请求体里的 `model` 字段自动分流。也可以通过环境变量只启动其中一部分模型服务。

## 适用资源

推荐给模型服务预留：

- CPU：12 核左右
- 内存：16 GB 左右
- 磁盘：建议至少 30 GB 可用空间

默认资源分配：

- 整个容器：10 核 / 14 GB
- embedding：6 个推理线程
- rerank-base：3 个推理线程
- rerank-v2：4 个推理线程
- 预留：约 1 到 2 核给系统、Docker、Zeabur 代理和突发波动

## 服务说明

| 服务 | 默认模型 | 内部端口 | 公网路径 | 用途 |
| --- | --- | --- | --- | --- |
| embedding | `BAAI/bge-m3` | `7997` | `/embedding/` | 文本向量化 |
| rerank-base | `BAAI/bge-reranker-base` | `7998` | `/rerank/` | 快速重排 |
| rerank-v2 | `BAAI/bge-reranker-v2-m3` | `7999` | `/rerank/` | 高质量重排 |

公网只暴露统一网关端口，embedding 和 rerank 只监听容器内的 `127.0.0.1`，不会直接暴露到公网。

## 为什么这样选

`BAAI/bge-m3` 的多语言和中文效果较好，适合作为默认 embedding 模型。`BAAI/bge-reranker-base` 更适合实时聊天和低延迟场景，`BAAI/bge-reranker-v2-m3` 更适合用户主动选择的高质量慢速重排场景。

## 文件说明

- `Dockerfile`：Zeabur 优先识别的 Docker 构建入口
- `start.sh`：按环境变量启动 embedding、rerank 和统一网关
- `gateway.py`：Bearer Token 鉴权、路径兼容和按 `model` 字段分流 rerank 请求
- `nginx.conf.template`：旧版 Nginx 网关配置，当前保留作兼容参考
- `docker-compose.yml`：本地 Docker Compose 启动入口
- `.env.example`：可调整的模型、线程、batch 和资源参数
- `.gitignore`：避免提交本地环境文件和缓存

## Zeabur 部署

1. 在 Zeabur 新建 Project。
2. 选择从 GitHub 仓库部署。
3. 如果 Zeabur 预览识别为 `static`，点击“配置”，将构建方式改为 Dockerfile。
4. Dockerfile 路径填写 `Dockerfile`。
5. 服务端口填写 `8080`，或保持环境变量 `PORT=8080`。
6. 在 Zeabur 环境变量中配置 `MODEL_API_KEY`，必须使用足够长的随机字符串。
7. 首次启动会下载 Hugging Face 模型，耗时较长属于正常现象。
8. 模型缓存会写入容器内的 Hugging Face 缓存目录；在支持持久卷的平台上，建议把 `/app/.cache/huggingface` 挂到持久卷。

Zeabur 如果自动识别失败，优先使用 `Dockerfile` 部署，而不是 static provider。

## 本地启动

复制环境变量示例：

```bash
cp .env.example .env
```

启动服务：

```bash
docker compose up -d
```

查看日志：

```bash
docker compose logs -f
```

停止服务：

```bash
docker compose down
```

如果需要删除模型缓存：

```bash
docker compose down -v
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MODEL_API_KEY` | 无 | 公网访问 Bearer Token，必填 |
| `PORT` | `8080` | 统一网关监听端口 |
| `ENABLE_EMBEDDING` | `true` | 是否启动 embedding 服务 |
| `ENABLE_RERANK_BASE` | `true` | 是否启动 rerank-base 服务 |
| `ENABLE_RERANK_V2` | `true` | 是否启动 rerank-v2 服务 |
| `MODEL_CPUS` | `10` | Docker Compose 下的整体 CPU 限制 |
| `MODEL_MEMORY` | `14G` | Docker Compose 下的整体内存限制 |
| `EMBEDDING_MODEL` | `BAAI/bge-m3` | embedding 模型 |
| `EMBEDDING_BATCH_SIZE` | `16` | embedding batch 大小 |
| `EMBEDDING_THREADS` | `6` | embedding BLAS/OMP 线程数 |
| `EMBEDDING_ENGINE` | `torch` | embedding 推理引擎，CPU 部署建议固定为 torch |
| `RERANK_BASE_MODEL` | `BAAI/bge-reranker-base` | 快速 rerank 模型 |
| `RERANK_BASE_BATCH_SIZE` | `8` | 快速 rerank batch 大小 |
| `RERANK_BASE_THREADS` | `3` | 快速 rerank BLAS/OMP 线程数 |
| `RERANK_BASE_ENGINE` | `torch` | 快速 rerank 推理引擎，CPU 部署建议固定为 torch |
| `RERANK_V2_MODEL` | `BAAI/bge-reranker-v2-m3` | 高质量 rerank 模型 |
| `RERANK_V2_BATCH_SIZE` | `4` | 高质量 rerank batch 大小 |
| `RERANK_V2_THREADS` | `4` | 高质量 rerank BLAS/OMP 线程数 |
| `RERANK_V2_ENGINE` | `torch` | 高质量 rerank 推理引擎，CPU 部署建议固定为 torch |

生成 `MODEL_API_KEY` 示例：

```bash
openssl rand -hex 32
```

只启动 embedding 时，Zeabur 环境变量可以这样配置：

```text
ENABLE_EMBEDDING=true
ENABLE_RERANK_BASE=false
ENABLE_RERANK_V2=false
```

此时 `/embedding/` 和 `/embedding/v1/` 可用，`/rerank/` 会返回 `404`，不会下载或加载 rerank 模型。

## Rerank 分流

两个 rerank 模型共用同一个公网 URL，网关会读取请求体里的 `model` 字段自动分流：

```text
model 包含 base：转发到 BAAI/bge-reranker-base
其他 rerank 请求：转发到 BAAI/bge-reranker-v2-m3
```

因此调用方可以只配置一个 rerank base URL，把模型选择交给用户：

```text
快速模式：BAAI/bge-reranker-base
高质量模式：BAAI/bge-reranker-v2-m3
```

建议快速模式作为默认，高质量模式限制候选数量和请求频率。

## 推荐 RAG 参数

- 向量召回 `top_k`：20
- rerank 候选数：10 到 20
- rerank `top_n`：5 到 10
- chunk 长度：300 到 800 tokens
- chunk overlap：50 到 100 tokens

CPU 部署不建议一次 rerank 50 条以上候选，容易导致延迟显著上升。

## 性能预期

在模型服务独占约 12c16g 的前提下：

- embedding 短文本请求：200 到 300 RPM 可以作为压测目标
- embedding 中等 chunk：100 到 250 RPM 更现实
- rerank 每次 10 个候选：100 到 250 RPM 需要结合文本长度实测
- rerank 每次 20 个候选：通常更适合按几十到一百多 RPM 规划

rerank 的真实压力应按 pair 数估算：

```text
每分钟 pair 数 = RPM × 每次候选数量
```

例如 200 RPM 且每次 10 个候选，就是 2000 pair/min。

## 接口接入

服务启动后只需要对外暴露一个域名：

- health check：`https://<your-zeabur-domain>/health`
- embedding base URL：`https://<your-zeabur-domain>/embedding/v1`
- rerank base URL：`https://<your-zeabur-domain>/rerank/v1`
- 兼容短路径：`/embedding/embeddings`、`/rerank/rerank`

所有模型接口都需要带鉴权头：

```bash
Authorization: Bearer <MODEL_API_KEY>
```

embedding 调用示例：

```bash
curl https://<your-zeabur-domain>/embedding/v1/embeddings \
  -H "Authorization: Bearer <MODEL_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-m3","input":"测试文本"}'
```

快速 rerank 调用示例：

```bash
curl https://<your-zeabur-domain>/rerank/v1/rerank \
  -H "Authorization: Bearer <MODEL_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-reranker-base","query":"什么是向量数据库？","documents":["向量数据库用于相似度检索","天气很好"]}'
```

高质量 rerank 调用示例：

```bash
curl https://<your-zeabur-domain>/rerank/v1/rerank \
  -H "Authorization: Bearer <MODEL_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-reranker-v2-m3","query":"什么是向量数据库？","documents":["向量数据库用于相似度检索","天气很好"]}'
```

如果调用方支持 OpenAI-compatible embedding，可以把 base URL 配成：

```text
https://<your-zeabur-domain>/embedding/v1
```

API Key 填 `MODEL_API_KEY` 的值。

## 鉴权行为

- `/health` 不需要鉴权，方便 Zeabur 做健康检查。
- `/embedding/` 需要 `Authorization: Bearer <MODEL_API_KEY>`。
- `/rerank/` 需要 `Authorization: Bearer <MODEL_API_KEY>`。
- 其他路径返回 `404`。

## Zeabur 识别为 static 的处理

如果 Zeabur 构建计划预览显示 provider 是 `static`，说明它没有按预期选择 Dockerfile。处理方式：

1. 不要直接点“部署”。
2. 点击“配置”。
3. 将 provider / runtime 改成 Dockerfile。
4. Dockerfile 路径填写 `Dockerfile`。
5. 端口填写 `8080`。
6. 添加环境变量 `MODEL_API_KEY`。
7. 再部署。

## 安全建议

当前配置已经增加 Bearer Token 鉴权，但这只解决“谁能调用”的问题，不解决高频合法请求导致的 CPU 压力。生产使用时仍建议在调用方或网关层增加限流，并定期轮换 `MODEL_API_KEY`。
