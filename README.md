# npu-vllm-ascend-deploy v1.0

昇腾 NPU 大模型推理部署通用技能(Claude Code Skill)——**经 4 次实测部署验证**(道通 A5 950DT ×2、华为云 A3 ×2),沉淀 20+ 实测坑位解法。

## 它能做什么

在昇腾 NPU 上把 vLLM-Ascend 适配的开源大模型(GLM / Qwen / DeepSeek / Kimi / Llama…)部署成 OpenAI 兼容推理服务,一条命令级对话覆盖全流程:

```
集群探测 → 模型确认 → 芯片+TP 校验 → 部署形式(单机/多机/PD 分离 xPyD)
→ 镜像准备(换源强拉/版本包现场构建) → 权重校验与三级暂存
→ 生成配置与脚本 → 严格顺序启动 → 端到端验证 → 运维交付
```

## 三种部署模式(自动路由)

| 模式 | 载体 | 入口 |
|------|------|------|
| 裸机 Docker(默认) | 自建集群,每节点一个容器 | `SKILL.md` 步骤 0~8 |
| MA-AscendCloud 高可用 | AscendCloud 版本包从零构建镜像 + RouteServer 六角色(ETCD/RS/Mooncake/P/D) | `references/modelarts-ascendcloud-ha.md` |
| MA-在线服务 | OBS 权重 + SWR 镜像 + CreateInferService API/控制台 | `references/modelarts-deploy.md` + `modelarts/` 全套工具链 |

## 安装

```bash
# 解压到 Claude Code 技能目录(重开会话生效)
unzip npu-vllm-ascend-deploy-v1.0.zip -d ~/.claude/skills/npu-vllm-ascend-deploy/
```

## 使用

直接对话触发,例如:

- "用 npu-vllm-ascend-deploy 把 GLM-5.3 以 3P1D 部署到集群"
- "帮我在 ModelArts 上部署 Qwen(专属池)"
- "按 6.5.938 版本包和指导文档做 MA 高可用部署"

首次在新集群使用会自动执行**步骤 0 探测**(芯片/网络/存储/冲突检查),随后按硬性确认点(AskUserQuestion)逐项与你确认模型、芯片 TP、拓扑与节点分配、权重路径、镜像来源——**所有决策你拍板,所有坑它绕开**。

## 目录结构

```
├── SKILL.md            入口: 流程编排/规范/步骤 0~8(裸机主线)
├── references/         知识层(7 份): 集群档案/硬件矩阵/形式决策/Mooncake PD/
│                       排障手册/实战案例库/MA 两模式指南
├── templates/          裸机模板: pd.sh(xPyD 通用)/single/multi_node/config.env/
│                       verify_inference.py/GLM-5.3 实战实例
├── scripts/            工具: cluster_ssh.ps1(批量SSH隧道)/fast_pull2.sh(换源拉镜像)/
│                       a5_hixlep(950 UB 通信离线包)
└── modelarts/          MA-在线服务工具链: create_infer_service.py/模板/指南(自包含)
```

## 内置的实战能力(节选)

- **quay 镜像被墙**: fast_pull2 多源轮换+并发分段+卡速自断 → docker load(8.2GB 实测拉通)
- **SFS 权重病理慢读**(37min/分片): /data→/dev/shm→SFS 三级暂存自动决策,RAM 加载 14s
- **MA 镜像构建四补丁**: openssl 三方冲突垫片/握手超时/ATB 路径/就绪超时(全部实测)
- **并行部署冲突检测**: 动手前查他人容器,防互打
- **启动顺序强制**: 全部 P → /health 200 → D → Proxy 最后;停止反向(-t 60 优雅停)
- **压测 SOP**: acs-bench 阶梯并发(1→512) + vllm bench serve

## 安全红线

凭据不落盘不进对话(仅凭据文件/环境变量);curl 白名单后缀匹配;用户输入拼接前正则校验;临时文件只进 /tmp 与 %TEMP%;节点可执行件仅限本 skill 自带。

## 版本

| 版本 | 日期 | 说明 |
|------|------|------|
| v1.0 | 2026-11-19 | 实战验证版: 4 案例沉淀(道通 950DT ×2 + 华为云 A3 ×2)、20+ 坑位解法、三模式自包含 |
