---
name: npu-vllm-ascend-deploy
description: "在昇腾 NPU 上用 vLLM-Ascend 部署开源大模型的通用技能,内置两种部署目标: ①裸机 Docker 模式(自建集群,每节点一个容器) ②ModelArts 模式(在线服务/专属池/OBS+SWR+CreateInferService,内置全套脚本模板指南)。支持任意 vllm-ascend 适配模型(GLM/Qwen/DeepSeek/Kimi/Llama 等),三种部署形式(单机/多机/PD 分离含 xPyD 如 3P1D)。裸机模式覆盖: 集群探测(npu-smi/Docker/SFS 挂载)→ 模型确认(查 vllm-ascend 适配文档)→ 资源规格(芯片细分 950DT/950PR + TP 四条件校验)→ 部署形式决策 → 镜像准备(quay 拉取/换源/离线 save-load)→ 权重校验与本地暂存(/data、/dev/shm 三级)→ config.env+启动脚本生成与自检 → 分发启动(严格顺序: 全部 Prefill → 全部 Decode → /health 200 → Proxy 最后)→ OpenAI 兼容验证 → 运维。ModelArts 模式覆盖 MA-0~MA-6(权重上 OBS/镜像推 SWR/脚本产物自检/API 或控制台部署/就绪验证)。芯片不预设: A3/A2/310P/950 均支持;950 系列才启用 hixlep/UB,A2/A3 走 RoCE;内置 Mooncake KV 传输规划、RDMA 挂载、quay 换源拉取、SFS 病理慢读规避等实战适配。Triggers: \"NPU 部署大模型\", \"昇腾部署\", \"裸机部署\", \"ModelArts 部署\", \"vllm-ascend 容器部署\", \"PD 分离\", \"3P1D\", \"xPyD\", \"Mooncake\", \"SFS Turbo 模型部署\", \"A3/910C\", \"A5/950DT/950PR\", \"GLM/Qwen/DeepSeek 部署到 NPU\"。"
tags: [ascend, npu, vllm-ascend, docker, baremetal, pd-disaggregation]
version: 1.0.0
---

# 昇腾 NPU 裸机容器化部署 vLLM-Ascend 大模型(通用)

## 概述

把 vllm-ascend 官方适配的开源大模型部署到昇腾 NPU,提供 OpenAI 兼容 RESTful API。**两种部署目标内置可选**(步骤 0 确认): 裸机 Docker 模式(本文件步骤 0~8)/ ModelArts 模式(`references/modelarts-deploy.md`,MA-0~MA-6)。裸机模式全流程: 集群探测 → 模型确认 → 资源规格 → 部署形式 → 镜像准备 → 权重校验 → 产物生成 → 分发启动 → 验证 → 运维。

三种部署形式(两种目标通用),**裸机模式下每个节点一律以 Docker 容器承载**(强制,不在宿主机直接装 vllm):
- **single**: 单节点单容器,`--tensor-parallel-size N` → `templates/single.sh`
- **multi_node**: 跨节点 Ray 集群,一个 vLLM 引擎横跨多节点 TP → `templates/multi_node.sh`
- **pd**: PD 分离,x 个 Prefill 引擎 + y 个 Decode 引擎 + 1 个 Proxy(如 **3P1D** = 3 Prefill 节点 + 1 Decode 节点,每节点 1 个独立引擎)→ `templates/pd.sh`

> **重要声明**: 基于 vLLM-Ascend 开源社区镜像,仅适用于功能验证、原型测试。生产环境的高可用、安全合规、可观测性要求,请勿直接使用。控制机到节点用 root + 密码 SSH,代理无鉴权——**服务端口只应暴露在内网**。

## 两种部署目标(步骤 0 时与用户确认)

本 skill 覆盖两条部署路径,**共用**模型确认(步骤 1)、资源规格(步骤 2)、部署形式决策(步骤 3)、安全与交互规范:

- **裸机 Docker 模式(默认,本文件步骤 0~8)**: 自建 NPU 服务器,每节点一个 Docker 容器,SSH + 共享存储操作。
- **ModelArts 模式(内置,两个子形态)**: ①在线服务形态——专属/公共资源池,OBS 权重 + SWR 镜像 + CreateInferService API/控制台部署,走 `references/modelarts-deploy.md`(MA-0~MA-6,配套 `modelarts/` 目录全套脚本模板);②**AscendCloud 高可用形态**——用户给 AscendCloud 版本包(如 6.5.938)+ 实践指导文档、要求"按版本包从零构建镜像 + RouteServer HA 部署"(推理),走 `references/modelarts-ascendcloud-ha.md`(基础镜像 + 现场构建业务镜像 + ETCD/RouteServer/Mooncake/P/D 六角色)。用户提到 ModelArts/资源池/SWR/OBS/版本包/RouteServer 时进入 MA 模式,按资源形态选子形态。

## 集群信息(先读)

机器清单、SSH 访问方式、凭据文件规范见 `references/cluster-info.md`;**换新模型/新集群时先查 `references/case-studies.md` 找最接近的实测案例作起点**。要点(2026-11-17 实测):
- 入口 EIP `<CLUSTER-EIP>` = 节点 `<ENTRY-NODE-IP>`;内网 NPU 节点 `.98 / .28 / .55 / .181`(4 节点,支撑 3P1D);每节点 **16 张 Ascend910、单卡 HBM 64GB**(A3 形态,勿套用 A5/950 参数)
- Windows 只能直达 EIP,内网节点经 SSH 端口转发隧道访问(`scripts/cluster_ssh.ps1` 已内置,密码认证,无需免密,4/4 实测通过)
- 凭据(密码)**不写入任何 skill 文件**,运行时从 `Desktop\<cred-dir>\机器信息.txt` 读取或向用户索取
- 模型权重共享存储 `/mnt/sfs_turbo/`(4 节点同挂),已实测存在 `models/GLM-5.3-w4a8-int`(W4A8 量化版)

## 核心流程总览

```
步骤 0  集群探测     连通性 → 每节点 npu-smi/docker/SFS/驱动/端口 → 产出节点清单表
步骤 1  模型确认     查 vllm-ascend 适配文档 → 候选清单 → AskUserQuestion 硬性 gate → 权重完整性校验
步骤 2  资源规格     芯片型号(自动探测+细分确认)→ TP 四条件校验 → 固化为方案输入
步骤 3  部署形式     single/multi_node/pd 三选一 + 节点角色分配表 → AskUserQuestion 确认
步骤 4  镜像准备     按模型文档定 tag → 各节点 pull / 离线 save-load → 容器内模块自检
步骤 5  产物生成     从 templates 填充 config.env + 启动脚本 → 产物自检关卡 → 分发到各节点
步骤 6  分发启动     严格顺序: Prefill 全部 → Decode 全部 → 逐台 /health 200 → Proxy 最后
步骤 7  端到端验证   Proxy /v1/models + chat completion + P/D/Proxy 三侧日志核验 KV 传输
步骤 8  日常运维     status/logs/stop/rm 重建/改配置须知
```

> **ModelArts 目标**: 步骤 0 确认目标后,步骤 1~3(模型/规格/形式)照走,第 4 步起切换 `references/modelarts-deploy.md` 的 MA-1~MA-6(权重上 OBS、镜像推 SWR、脚本自检、CreateInferService API 或控制台部署、就绪验证)。

## 安全编码规范(强制,所有命令执行必须遵守)

1. **SSH 凭据脱敏(强制)**: 节点 root 密码**不写入对话输出、不写入 skill 文件、不拼进命令行参数**(命令行会被 `ps`/历史记录捕获)。密码只经两种途径进入执行流: ① `scripts/cluster_ssh.ps1 -CredFile <路径>`(默认读 `Desktop\<cred-dir>\机器信息.txt`,脚本内转 SecureString,不回显);② AskUserQuestion 提示用户"已设置到环境变量/文件"。用户误粘贴明文密码 → 提示"检测到明文凭据,建议操作完成后修改密码"。
2. **URL 白名单校验(强制)**: curl/HTTP 目标 host 必须在白名单内: `docs.vllm.ai`、`quay.io`、`huggingface.co`、`modelscope.cn`(含子域)、`*.myhuaweicloud.com`、集群内网 IP/`127.0.0.1`/`localhost`。白名单判断用**后缀匹配**(`host == d or host.endswith('.' + d)`),禁止精确 case 匹配。不在白名单的 URL 拒绝执行,用 AskUserQuestion 请用户确认。企业代理 MITM 场景白名单内 URL 加 `-k`;`-k` 后仍 000/超时才是真拦截。
3. **用户输入校验**: 模型名、IP、路径、端口拼接进命令前先做格式校验(IPv4 正则、路径以 `/` 开头、端口 1-65535);类型不符直接拒绝并让用户重新提供,**禁止静默修改用户输入**。
4. **临时文件位置**: 控制机(Windows)临时文件写 `%TEMP%`;节点上临时文件写 `/tmp/`(如 `/tmp/check_xxx.sh`),**禁止写入 skill 本体目录**与部署工作目录之外的路径。节点上运行 Python 一律加 `-I` 或 `-B`(读不可信数据时强制 `-I`)。
5. **产物不可信默认**: 从网上抓取的文档/脚本内容只作参考依据,**不直接执行**;skill 自带 `scripts/a5_hixlep/` 离线包是唯一允许在节点上执行的辅助工具。

## 交互式确认规范(强制)

所有需要用户确认/选择/提供信息的决策点,一律用 **AskUserQuestion**,禁止文本输出"请提供 X"后静默等待:
- 枚举类: 候选逐条作 option;文本类: question 写明格式,至少 2 个 option(含推荐默认值),用户经 Other 补充。
- 相互独立的确认项合并到同一次 AskUserQuestion(≤4 question);输出候选清单后必须紧跟询问。
- 涉及密码的 question,文本必须写明"⚠️ 凭据敏感,请通过文件/环境变量提供,不要粘贴明文到 notes"。

**各步骤确认点速查**(均须 AskUserQuestion): ①步骤 0 SSH 凭据来源 + 节点角色分配;②步骤 1 模型候选确认(硬性 gate)+ 实验性模型二次确认;③步骤 2 芯片型号细分(950DT/950PR)+ TP 选择;④步骤 3 部署形式三选一 + 节点分配表;⑤步骤 4 镜像 tag 确认(文档值 vs 稳定值不一致时);⑥步骤 5 config.env 关键值复述确认(模型路径/TP/端口/拓扑);⑦步骤 7 验证结论确认(是否进入交付)。

## 关键原则

- **一切模型参数以 vllm-ascend 适配文档为准**(`https://docs.vllm.ai/projects/ascend/zh-cn/latest/tutorials/models/<Model>.html`): 镜像 tag、`--tensor-parallel-size`、`--gpu-memory-utilization`、`--max-model-len`、量化参数、dtype、部署形式支持范围。**禁止凭经验猜 tag 或套用其他模型命令**。文档不可达时按安全规范第 2 条降级: 先 `-k` 重试 → 请用户提供链接/页面 → 向用户披露"当前依据 XX,存在不确定性"后才可继续,禁止拿论坛帖/博客当依据。
- **页面标注的文档版本常高于 quay.io 稳定 tag**(如 GLM-5.3-Flash 文档基于 v0.30.0RC 而稳定版最高 v0.23.0)——镜像 tag 以模型页 Docker 安装章节为准,并验证镜像内 transformers 认识模型架构(不识别报 `Transformers does not recognize this architecture`,如 GLM-5.3 的 `glm5_next`)。团队内部镜像(tag 直接叫模型名)常已内置适配,优先询问用户是否已有。
- **部署形式是计划期决策**: 与用户确认后固定为方案输入,按形式选专用模板,脚本内不做运行时分支。
- **启动顺序强制**: Prefill 全部就绪 → Decode 全部就绪(逐台 `/health` 200)→ **最后才启动 Proxy**;反向启动会出现请求打到未就绪后端。
- **首次启动很慢**(权重加载 + 图编译 10~20 分钟),`docker ps` 显示 Running ≠ 服务就绪,必须以 `/health` HTTP 200 为准。

---

## 步骤 0: 集群探测

1. **确认凭据来源**(AskUserQuestion): 默认读 `Desktop\<cred-dir>\机器信息.txt`(第 1 行 EIP、第 2 行用户名、第 3 行密码、第 4 行起内网节点 IP);用户也可指定其他文件或手动提供(走 Other,不粘明文)。
2. **连通性矩阵**: 用 `scripts/cluster_ssh.ps1` 依次测: 控制机 → 跳板、控制机 → 各节点直连、跳板 → 各节点。**优先直连**;直连不通走跳板转发(见 cluster-info.md 两种通道)。形成"控制机→节点"可用通道表。
3. **每节点环境探测**(经通道批量执行,产出节点清单表):

```bash
hostname; npu-smi info | head -30          # 芯片型号/卡数/显存/占用
npu-smi info -t spod-info -i 0 2>/dev/null # SuperPod 归属(PD 跨节点 UB 通信前提)
docker --version && docker info --format '{{.ServerVersion}} {{.OperatingSystem}}'
df -h /mnt/sfs_turbo && ls /mnt/sfs_turbo # SFS Turbo 是否挂载、模型目录可见
ls /dev/davinci* /dev/davinci_manager /dev/hisi_hdc /dev/ummu 2>&1 | head
ls -ld /usr/local/Ascend/driver /etc/hixlep /etc/hccl_rootinfo.json 2>&1
ip -4 -brief addr; ss -lntp | grep -E ':(8000|8100|8200|36000|36100)' || true
```

4. **记录到方案**: 节点 IP × 芯片型号(950DT/950PR/910B…细分!)× 卡数 × Docker × SFS 挂载 × 端口占用 × 通道(直连/经跳板)。任一项不满足(如缺 SFS 挂载、端口被占)先向用户披露并确认处理方式。

## 步骤 1: 模型确认(硬性 gate)

1. **抓取模型索引页** `https://docs.vllm.ai/projects/ascend/zh-cn/latest/tutorials/models/index.html`(白名单校验 + `-k`): 模型清单在**侧栏导航 `md-nav__link`** 中,不在正文;按用户模型名大小写不敏感过滤出**全部**候选页面。用户名模糊(如"GLM5.3"、"Qwen")→ 整理完整候选清单(候选模型 | 权重版本 | 硬件要求 | 镜像 tag | 部署形式)展示。
2. **AskUserQuestion 确认**(无论名字多精确都必须过): 每个候选一个 option;用户明确授权"按推荐选"也须复述确认。
3. **实验性模型二次确认**: 模型页**正文**(剥离 `<nav>` 后)标注 Experimental/实验性且归属目标模型+目标芯片 → 披露 ①社区实验版本 ②不保证部署成功 ③不建议生产,options `继续(接受风险)`/`放弃换稳定版`,确认后记录到方案。
4. **权重路径必须向用户确认(硬性 gate,禁止假设、禁止重新下载)**: AskUserQuestion 问清模型数据在哪里(默认候选列出步骤 0 探测到的 `/mnt/sfs_turbo/` 下实际目录,如 `models/GLM-5.3-w4a8-int`,附大小/分片数/是否量化版;用户指定其他路径则用用户的)。用户已下载的权重**只校验、不重下**;未下载时才与用户确认下载方式(ModelScope 镜像内下载到 SFS)。
5. **权重完整性校验**(路径确认后,任一节点执行): `config.json` 存在 + safetensors 分片头完整性 + 总字节数对上 `model.safetensors.index.json` 的 `total_size`(校验脚本见 `references/mooncake-pd-notes.md` 附录;校验脚本是本地生成的,经通道写入 `/tmp/` 执行)。
6. 记录: 模型 ID、权重格式(BF16/W8A8/...)、文档链接、MODEL_PATH 实际路径(用户确认值)。

## 步骤 2: 资源规格确认(芯片型号 + TP)

1. **芯片型号**: 步骤 0 已探测到实际型号(比用户口述更可靠),与用户复述确认;**950 系列必须细分 950DT(96GB)/950PR(128GB)**——同模型两者文档示例参数可能不同。速查表见 `references/hardware-matrix.md`。
2. **TP 合法候选 = 四条件交集**(只把合法值给用户选):
   - **头数约数**: 模型注意力头数 H 的正约数(H 从模型文档正文或权重 `config.json` 取,多模态/混合架构查 `text_config`; MoE+线性注意力混合架构头数以文档为准)
   - **卡数档位**: 非 A3 芯片 1/2/4/8;A3(910C) 2/4/6/8/16
   - **文档 TP 值**: 候选必须 ≥ 模型文档启动示例的 `--tensor-parallel-size`
   - **显存可容纳**: `(单卡显存 × gpu_memory_utilization) − 权重GB/TP ≥ 1GB`(gpu_memory_utilization 从文档示例取,不查到不填经验值;权重 GB 按 safetensors 实际体积)。违反 → 启动即崩 `ValueError: No available memory for the cache blocks`(`Available KV cache memory: -Y GiB`)
3. AskUserQuestion 选 TP(每个 option 带显存核算式);用户经 Other 自定义输入须重跑四条件校验,不合法直接拒绝。
4. 记录: `CHIP_MODEL`、`TP_SIZE`、`ATTENTION_HEADS`、单卡显存——后续模板填充直接引用,不再询问。

## 步骤 3: 部署形式确认 + 节点分配

1. 按模型文档(`references/deployment-form-decision.md` 线索表)整理推荐形式与依据,AskUserQuestion 三选一: `single` / `multi_node` / `pd`。
2. **pd 形式确定 xPyD 拓扑**: x 个 Prefill 引擎 + y 个 Decode 引擎(每节点 1 引擎 = 1 容器),**Proxy 不占 NPU**,与任一 Prefill 节点同机部署(默认第一个 Prefill 节点)。3P1D = 3P + 1D = 4 节点。文档给出的 prefill/decode 各自并行参数(TP/DP-local/EP/PP)填入 config.env 对应角色变量。
3. **节点分配表**(AskUserQuestion 确认): 节点 IP → 角色(P-i / D-j / proxy 同机)。默认按集群清单顺序: 前x台 Prefill、后y台 Decode。确认后固定。
4. 记录: 形式、拓扑(xPyD)、分配表、各角色端口规划(HTTP: P=8100 D=8200 Proxy=8000;KV: 36000+engine_id×10;见 `references/mooncake-pd-notes.md`)。

## 步骤 4: 镜像准备

1. **定 tag**: 从模型页 Docker 安装章节取 `quay.io/ascend/vllm-ascend:<tag>`;带芯片变体后缀按目标芯片选(`-a3`/`-310p`,无后缀默认 A2;A5/950 常见模型名后缀 tag 如 `qwen3.8-a5`)。文档 tag 与 quay 稳定 tag 不一致 → AskUserQuestion 披露并让用户选(换内部镜像 / 换稳定模型 / 接受 RC)。
2. **各节点准备镜像**(两节点以上必须 digest 或同 tag 内容一致):
   - 可出网节点: `docker pull <IMAGE>` 后 `docker image inspect <IMAGE> --format '{{.RepoDigests}}'` 取 digest 固定。
   - 内网节点: 出网机 `docker save -o /tmp/<name>.tar <IMAGE>` → 通道传输 → `docker load -i`。
3. **容器内模块自检**(每节点,任一节点执行亦可,镜像相同即可):

```bash
docker run --rm --entrypoint bash <IMAGE> -lc '
set -e
python3 -c "import vllm, vllm_ascend; print(vllm.__version__)"
python3 -c "import transformers; print(transformers.__version__)"
python3 -c "import mooncake.engine" 2>/dev/null || echo "WARN: no mooncake (PD 需要时将失败)"
test -f /vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py || echo "WARN: proxy example missing"
'
```

   transformers 版本必须认识模型架构(实验性新架构如 `glm5_next` 需新版;不认识 → 换镜像,见 troubleshooting)。

## 步骤 5: 产物生成(模板填充 + 自检)

1. **部署工作目录**: 优先放共享存储 `/mnt/sfs_turbo/deploy/<模型简称>-<形式>/`(写一次全节点可见,config.env 全节点同一份,靠 NODE_IP 自动判角色);不可用时每节点 `/root/<模型简称>-<形式>/` 各放一份(经通道分发,内容必须一致)。
2. **按形式选模板**: single → `templates/single.sh`;multi_node → `templates/multi_node.sh`;pd → `templates/pd.sh`。复制为工作目录 `<single|mn|pd>.sh`,同目录放 `config.env`(按 `templates/config.env.example` 填充)。所有取值来源: 模型文档 + 步骤 2/3 已确认方案,**生成前必须重读模板文件以磁盘内容为准,禁止凭记忆填数**。
3. **产物自检关卡**(强制,违反则重写):
   - 硬性: `MODEL_PATH` 下有 `config.json`;TP/DP 值与步骤 2 方案一致;PD 的 KV 端口规划全局唯一且 ≥28000(避开 Mooncake 随机端口范围 [20000, 20000+卡数×1000));量化参数 × 权重交叉校验(带 `--quantization*` 则权重目录必须有 `quant_model_description.json`,反之量化权重未带量化参数要 WARN);JSON 参数经 bash 数组传递不丢引号;PD 三角色端口互不冲突。
   - 软性(向用户披露): MoE 模型 HCCL_BUFFSIZE 预算(GLM-5.3 实测需 ≥1628,保守 2415;见 troubleshooting);`--enforce-eager` 必要性(混合注意力架构 TP≥8 实测 CUDAGraph 崩溃);SFS Turbo 读权重比本地盘慢的预期。
4. **AskUserQuestion 复述确认** config.env 关键值(模型路径/served-model-name/TP/端口/拓扑/engine_id 规划)后才可分发。

## 步骤 6: 分发与启动(顺序强制)

1. **分发**: 工作目录内容(脚本+config.env,PD 另加 a5_hixlep 离线包目录)分发到全部参与节点并 `chmod +x`;通道用法见 cluster-info.md。分发后 `sha256sum` 比对各节点文件一致。
2. **预检**: 每节点 `./pd.sh check`(single/mn 同理 `check` 子命令)——本机 IP 角色匹配、网卡、设备节点(`/dev/davinci*` 等)、驱动路径、镜像存在、`MODEL_PATH` 就绪。预检不过禁止启动。
3. **按序启动**(每节点独立后台执行,ssh 会话退出不中断——容器 `--restart unless-stopped` 已保证):
   - **pd**: 先全部 Prefill 节点 `./pd.sh prefill` → 等到**每台** Prefill `curl http://<P_IP>:8100/health` 返回 200(首次 10~20 分钟,轮询间隔 60s)→ 全部 Decode 节点 `./pd.sh decode` → 每台 Decode `/health` 200 → **最后** Proxy 节点 `./pd.sh proxy`。
   - **single**: 单节点 `./single.sh start` → 本机 `/health` 200。
   - **multi_node**: head 节点 `./mn.sh head` → 各 worker `./mn.sh worker` → head `./mn.sh serve` → `/health` 200。
4. 启动期间用 `./pd.sh logs prefill|decode|proxy` 跟踪;卡死/报错对照 `references/troubleshooting.md`。

## 步骤 7: 端到端验证

1. **后端逐台**: 每个 Prefill/Decode 的 `/health` 200 + `/v1/models` 含 served-model-name。
2. **Proxy 入口**(pd): `/v1/models` 正常;发一条 chat completion(经 Proxy,非直连后端!):

```bash
curl --noproxy '*' --fail-with-body --max-time 300 http://<PROXY_IP>:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<served-model-name>","messages":[{"role":"user","content":"请只回答:部署成功"}],"max_completion_tokens":64}'
```

   或 `python3 templates/verify_inference.py --base-url http://<PROXY_IP>:8000 --model <name>`(先推到任一节点 /tmp)。
3. **三侧日志核验**(仅后端健康 ≠ PD 链路通): Prefill 日志出现请求处理与 KV 传输、Decode 日志出现对应接收、Proxy 日志有 prefill→decode 路由记录,无 Mooncake/UB 报错。
4. **性能压测(用户要求时)**: 方法库见 `references/case-studies.md`(acs-bench 阶梯并发 SOP + vllm bench serve);PD 分离压测端点必须打 Proxy。
5. 向用户交付: 调用端点 `http://<PROXY_IP>:8000/v1`(或 single 的 `http://<节点IP>:8000/v1`)、模型名、三侧日志命令、运维命令。AskUserQuestion 确认交付。

## 步骤 8: 日常运维

```bash
./pd.sh status                # 容器状态
./pd.sh logs prefill|decode|proxy   # 跟踪日志(Ctrl+C 退出不停容器)
./pd.sh stop <role>           # 停止
./pd.sh health                # 全部后端 /health 巡检
# 改 config.env 后必须 rm 重建(docker start 不应用新参数):
./pd.sh stop prefill && docker rm <容器名> && ./pd.sh prefill
```

- 顺序同样适用: 先 P 后 D 最后 Proxy;停机反向(先 Proxy)。
- 清理全部: `./pd.sh clean`(停并删所有角色容器)。

## 何时不使用本技能

- 用户要在 **GPU(CUDA)** 部署 → 本 skill 的设备挂载/HCCL/hixlep 全部不适用。
- 训练/微调(如 ms-swift)→ 不在本 skill 范围。
- ModelArts 部署**属于本 skill**(走 `references/modelarts-deploy.md` 的 MA 模式),不是例外。
