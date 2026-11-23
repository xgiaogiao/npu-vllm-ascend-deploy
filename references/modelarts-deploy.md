# ModelArts 部署模式(在线服务)

> **备注**: 本模式的脚本/模板/指南(`modelarts/` 目录)取自华为云 skill **`huawei-cloud-modelarts-vllm-ascend-model-deploy`**(v1.0.0),并叠加了本 skill 裸机实战沉淀的换源拉取、产物自检等适配;内容已完整内置,无需再找原 skill。

本 skill 支持两种部署目标,步骤 0~8 为**裸机 Docker 模式**;当资源在华为云 **ModelArts 推理平台**(在线服务/专属资源池)时,走本文件的 **MA 模式**。两种模式共用: 模型确认(步骤 1)/资源规格(步骤 2)/部署形式决策(步骤 3)/安全与交互规范;差异只在"载体"(裸机容器 vs ModelArts 服务)。

**MA 模式文件布局**(全部在本 skill 内,自包含):
```
modelarts/
├── references/   # API 部署指南/控制台 9 步指南/IAM 权限/产物自检标准/CLI 安装/验收标准/验证方法/模型文档抓取法
├── scripts/      # create_infer_service.py(创建服务,强制经它提交)/get_master_ip.py(多机角色判定)/
│                 # upload_code_to_obs.py+obs_upload.sh(产物上 OBS)/pull_push_image.sh(quay→SWR)/
│                 # check_artifacts.py(产物自检)/download_model.py/test_inference.py
└── templates/    # start_vllm.{single,multi_node,pd}.sh + health_check.sh(ModelArts 专用启动/探针模板)
```

## MA-0 模式判定(AskUserQuestion)

用户满足任一即走 MA 模式: ①说要"ModelArts/在线服务/专属池/公共池" ②权重镜像要放 OBS/SWR ③资源是 ModelArts 资源池而非自建服务器。混合场景(自建集群+MA 管理)以用户指定为准。

## MA-1 前置条件核对(缺失即让用户补齐)

| 项 | 说明 |
|----|------|
| 华为云账号 | 已开通 ModelArts/OBS/SWR + 实名认证;OBS AK/SK 与 Endpoint(凭据按安全规范,禁明文) |
| OBS 桶 | 存权重+启动/探针脚本,建议同区域 |
| SWR | 存 vllm-ascend 镜像,需组织名+登录密钥 |
| 资源池 | 专属(需池 ID,支持多机/自定义规格)或公共(免 ID,仅预置规格);**芯片型号必确认,950 系列细分 DT/PR** |
| 域名/工作空间 | `modelarts.<region>.myhuaweicloud.com`;工作空间名→API 查 workspace-id |

## MA-2 权重与镜像准备

1. 权重: HuggingFace/ModelScope 下载(`modelarts/scripts/download_model.py`)→ `upload_code_to_obs.py`/`obs_upload.sh` 上传 OBS(路径格式 `obs://<bucket>/model/<模型名>`,精确到模型目录)。
2. 镜像: 按步骤 1 确认的模型文档取 tag → `pull_push_image.sh` 拉 quay 并推 SWR(格式 `swr.<region>.myhuaweicloud.com/<org>/<name>:<tag>`)。**拉取被墙时用本 skill troubleshooting 第〇节的换源方案(hlmirror/fast_pull2)先拉到任一有外网机器再推 SWR**。

## MA-3 启动/探针脚本产物

1. 按步骤 3 确认的部署形式选模板: `modelarts/templates/start_vllm.single.sh`(单机)/ `start_vllm.multi_node.sh`(多机 Ray)/ `start_vllm.pd.sh`(PD 三角色,`VLLM_ROLE=proxy|prefill|decode` 由平台 3 个推理单元注入,PD 的 proxy 不耗卡)。
2. 从模型适配文档填充参数(同裸机模式步骤 5 的产物自检关卡),连同 `health_check.sh`、`get_master_ip.py`、`load_balance_proxy_server_example.py`(PD 用)打包。
3. **过 `modelarts/scripts/check_artifacts.py` 自检**(硬性+软性项,对照 `modelarts/references/artifact-check.md`),再上传 OBS。

## MA-4 创建在线服务(二选一)

- **方式 A(API 自动)**: **必须**经 `modelarts/scripts/create_infer_service.py create` 提交(其 `validate_request_body()` 本地拦截必填缺失;禁止手写脚本直接 POST)。
- **方式 B(控制台手动)**: 按 `modelarts/references/modelarts-console-guide.md` 的 9 步点击指导,关键值与方式 A 相同。

**请求体硬规则**(违反=必失败,详见 `modelarts/references/api-deployment-guide.md`):
1. 顶层平铺: `name`/`type`/`group_configs[]`/`runtime_config`,禁用旧版 `service.deployment.roles[]` 包裹
2. 每个推理单元必带 `flavor`(专属池从池 flavors 按 `ascend.npu` 取;公共池从规格列表取);**PD 的 proxy 单元不耗卡: 专属池用 custom_spec card=0,公共池用 CPU 规格(vcpus≥4/内存≥16GB)**
3. `group_configs[].secret_type: "agency"`(OBS 挂载委托认证;改其他字段后必须复查未丢)
4. `runtime_config.service_invoke.port` = 启动脚本 PORT(8080);`service_limit` 三项必填: `request_timeout=300`(默认 30s 会掐断大模型首请求,报 8909)/`request_size_limit=20`/`rate_limit`
5. 健康检查: `failure_threshold=300`/`initial_delay_seconds=300`/`period_seconds=60`
6. **`deploy_timeout_minutes: 300` 必须显式设**(默认 20~60min 不够大模型首启,必超时失败)
7. workspace: POST 放 body 顶层 `workspace_id`;所有 GET 接口 URL 双查询参数 `?workspaceId=X&workspace_id=X` + 头
8. token: IAM API 获取 + Python 正则完整提取(禁 shell 管道,会丢字符);950 系列参数按细分型号取
9. 多机/PD: 注入 `GLOBAL_RANK_TABLE_FILE_PATH`/`POD_IP`,角色判定走 `get_master_ip.py`;PD 三单元共享 code 目录,仅 `VLLM_ROLE` 不同

## MA-5 就绪与端点

轮询服务状态至 `RUNNING`(大模型首启 10~20 分钟,探针窗口按上表放宽);取调用端点+鉴权信息。

## MA-6 验证

`modelarts/scripts/test_inference.py` 或 curl 调 `/v1/chat/completions`(同裸机步骤 7 的三侧日志核验思路,MA 看 Pod/实例日志)。

## MA 常见错误码速查

| 码 | 含义/处理 |
|----|-----------|
| 8003 Cannot find a specific flavor | unit_configs 缺 flavor 字段 |
| 6404 Flavor not found | flavor id 不存在(误用节点池规格) |
| 8084 No available resource | 请求体必填字段缺失被误报为资源问题(host_cache/image.source/recovery 等) |
| 8037 RateLimit must not be null | service_limit.rate_limit 缺失 |
| 8909 request timeout: 30s | request_timeout 未设 300 |
| 8162/8163 | OBS 挂载认证缺 secret_type:agency |
| 8179 Resource pool does not exist | body 顶层缺 workspace_id |
| APIGW.0301 decrypt token fail | token 复制截断,重取 |

完整排障见 `modelarts/references/*.md` 与本 skill `references/troubleshooting.md`(平台无关部分通用)。
