# BGE M3 Zeabur CPU 部署

这是一个面向 Zeabur + Docker Compose 的 CPU-only 向量模型和重排模型部署项目。默认使用 `BAAI/bge-m3` 提供 embedding 服务，使用 `BAAI/bge-reranker-base` 提供 rerank 服务。

## 适用资源

推荐给模型服务预留：

- CPU：12 核左右
- 内存：16 GB 左右
- 磁盘：建议至少 30 GB 可用空间

默认资源分配：

- embedding：6 核 / 8 GB
- rerank：4 核 / 6 GB
- 预留：约 2 核 / 2 GB 给系统、Docker、Zeabur 代理和突发波动

## 服务说明

| 服务 | 默认模型 | 端口 | 用途 |
| --- | --- | --- | --- |
| embedding | `BAAI/bge-m3` | `7997` | 文本向量化 |
| rerank | `BAAI/bge-reranker-base` | `7998` | 检索结果重排 |

## 为什么这样选

`BAAI/bge-m3` 的多语言和中文效果较好，适合作为默认 embedding 模型。CPU 场景下，rerank 的计算压力通常比 embedding 更明显，所以默认选择更稳的 `BAAI/bge-reranker-base`。如果后续压测确认 CPU 余量足够，可以把 rerank 模型切到 `BAAI/bge-reranker-v2-m3`。

## 文件说明

- `docker-compose.yml`：Zeabur / Docker Compose 部署入口
- `.env.example`：可调整的模型、线程、batch 和资源参数
- `.gitignore`：避免提交本地环境文件和缓存

## Zeabur 部署

1. 将本仓库推送到 GitHub。
2. 在 Zeabur 新建 Project。
3. 选择从 GitHub 仓库部署。
4. Zeabur 识别 `docker-compose.yml` 后会创建 `embedding` 和 `rerank` 两个服务。
5. 首次启动会下载 Hugging Face 模型，耗时较长属于正常现象。
6. 模型缓存会写入 Docker volume，不会写入宿主机全局 Python 或 Hugging Face 缓存目录。

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
| `EMBEDDING_MODEL` | `BAAI/bge-m3` | embedding 模型 |
| `EMBEDDING_BATCH_SIZE` | `16` | embedding batch 大小 |
| `EMBEDDING_THREADS` | `6` | embedding BLAS/OMP 线程数 |
| `EMBEDDING_CPUS` | `6` | embedding 容器 CPU 限制 |
| `EMBEDDING_MEMORY` | `8G` | embedding 容器内存限制 |
| `RERANK_MODEL` | `BAAI/bge-reranker-base` | rerank 模型 |
| `RERANK_BATCH_SIZE` | `8` | rerank batch 大小 |
| `RERANK_THREADS` | `4` | rerank BLAS/OMP 线程数 |
| `RERANK_CPUS` | `4` | rerank 容器 CPU 限制 |
| `RERANK_MEMORY` | `6G` | rerank 容器内存限制 |

## 模型切换

如果要测试效果更强但 CPU 压力更大的 rerank 模型，可以在 Zeabur 环境变量或 `.env` 中改为：

```bash
RERANK_MODEL=BAAI/bge-reranker-v2-m3
RERANK_BATCH_SIZE=4
RERANK_THREADS=4
RERANK_CPUS=5
RERANK_MEMORY=8G
```

切换后建议观察 CPU、内存、P95 延迟和请求排队情况。

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

服务启动后：

- embedding base URL：`http://<host>:7997`
- rerank base URL：`http://<host>:7998`

如果在同一个 Zeabur Project 内部调用，可以优先使用 Zeabur 的内部服务域名，避免公网绕行。

## 安全建议

模型服务不建议直接裸露公网。如果必须暴露公网，建议在前面增加鉴权、限流或网关层，避免被外部请求刷满 CPU。
