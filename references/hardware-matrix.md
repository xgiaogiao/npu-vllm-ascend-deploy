# 昇腾芯片型号与资源规格速查

> 速查参考,数值以昇腾官网与 vllm-ascend 适配文档为准;不确定时以 `npu-smi info` 实测 + 向用户确认为准,不要猜。

## 一、芯片型号 → 关键规格

| 芯片型号(代际) | 典型产品形态 | 单卡显存参考 | TP 卡数档位 | 定位 |
|----------------|--------------|--------------|-------------|------|
| 910B 系列(A2) | Atlas 800I/800T A2、900 A2 | 910B3: 64GB;910B4(推理版): 32GB | 1/2/4/8 | 大模型推理主力,文档示例最多 |
| 910C(A3) | Atlas 900 A3 等 | 以官方规格为准 | 2/4/6/8/16 | 新一代,注意 FP8 等特性支持 |
| **950 系列(A5)** | **950DT / 950PR** | **950DT: 96GB;950PR: 128GB** | 1/2/4/8 | 新一代高显存,**必须细分型号** |
| 310P | Atlas 300I Duo / 300V | 24GB 量级 | 1/2/4/8 | 推理卡,只适合 7B 以下小模型 |

## 二、950 必须细分 950DT / 950PR(强制)

用户答"A5"/"950"时必须细分确认(步骤 0 `npu-smi info` 实测为准):

| 差异维度 | 950DT | 950PR |
|----------|-------|-------|
| 单卡显存 | 96GB | 128GB |
| 文档示例差异 | 如 Qwen3.8-27B: `--max-model-len 131072` + `--gpu-memory-utilization 0.85` | 同模型: `--max-model-len 256000` + `--gpu-memory-utilization 0.9` |
| 权重版本 | 以模型文档为准(BF16 / w8a8-mxfp8) | 以模型文档为准(w8a8 推荐 / w8a8-mxfp8) |

两者常共用同一镜像 tag(如 `qwen3.8-a5`),但启动参数按各自文档示例提取,不得互相套用。

## 三、芯片 × 模型规模常见配置(经验值,以适配文档为准)

| 芯片 | 7B 以下 | 7B | 14B~32B | 72B+/MoE 大模型 |
|------|---------|-----|---------|------------------|
| 910B3(64GB) | 1 卡 | 1 卡 | 2~4 卡 | 8 卡或多机 |
| 910B4(32GB) | 1 卡 | 2 卡 | 4~8 卡 | 不推荐 |
| 950DT(96GB) | 1 卡 | 1 卡 | 1~2 卡 | 以文档为准(GLM-5.3 实测 8 卡 TP8 或 PD) |
| 950PR(128GB) | 1 卡 | 1 卡 | 1 卡 | 以文档为准 |
| 310P(24GB) | 1 卡 | 不推荐 | 不支持 | 不支持 |

## 四、TP 合法性四条件(步骤 2 执行细则)

合法 TP 候选 = **头数约数 ∩ 卡数档位 ∩ 文档 TP 值(候选 ≥ 文档示例值) ∩ 显存可容纳**。

- 头数 H: 模型文档正文 / 权重 `config.json`(混合架构查 `text_config.num_attention_heads`,先查顶层再回退嵌套)
- 显存可容纳: `(单卡显存 × gpu_memory_utilization) − 权重GB/TP ≥ 1GB`;gpu_memory_utilization 必须从文档示例取(不同芯片×权重版本取值不同),查不到才用兜底经验值(A2/950PR 0.9、950DT/A3 0.85)并向用户披露
- 权重 GB: 优先 safetensors 实际体积求和(`du -sh` 或索引 total_size),其次按 dtype 估算(BF16=2B/参数,FP8/INT8=1B/参数)
- 交集为空: 文档明确给出的 TP 示例值可作候选;否则提示换量化权重或更大显存芯片,由用户决策
- 违反显存条件的崩溃特征: `ValueError: No available memory for the cache blocks`,日志 `Available KV cache memory: -<Y> GiB` 负值

## 五、A5(950)系列特有: UB 超平面通信

- A5 的跨卡/跨节点 KV 与集合通信走 **UB(UniBuffer)超平面**,PD 分离 P↔D KV 传输依赖 `hixlep` endpoint 文件(`/etc/hixlep/ub_endpoint_npu_*.json`);缺失时用 skill 内置离线包 `scripts/a5_hixlep/` 生成(pd.sh 自动,细则见 `references/mooncake-pd-notes.md`)
- A2(910B)/A3(910C)走 RoCE,不需要 hixlep
- 仅管理 IP ping 通**不能**证明 NPU 数据链路正常;跨节点 PD 前核对 `npu-smi info -t spod-info`(SuperPod 归属)
