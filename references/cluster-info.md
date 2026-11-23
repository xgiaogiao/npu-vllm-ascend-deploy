# 集群信息与访问方式

> 密码不入本文件。运行时从凭据文件读取或向用户索取(AskUserQuestion,禁止明文进对话)。

## 机器清单(2026-11-17 实测探测)

| 节点 | 内网 IP | hostname(novalocal 后缀) | 默认角色(3P1D) |
|------|---------|---------------------------|------------------|
| 入口(EIP `<CLUSTER-EIP>` 绑定此机) | `<ENTRY-NODE-IP>` | <CLUSTER-NODE-HOST>-**00002** | Prefill-0 + Proxy |
| 节点 2 | `<NODE1-IP>` | ...-01-**00001** | Prefill-1 |
| 节点 3 | `<NODE2-IP>` | ...-01-**00003** | Prefill-2 |
| 节点 4 | `<NODE3-IP>` | ...-01-**00004** | Decode-0 |

**2026-11-17 实测环境**(4/4 节点全部验证通过):
- 系统 openEuler aarch64,openEuler bash 5.1.8;Docker 27.2.0;npu-smi 25.2.1
- **每节点 16 张 Ascend910、单卡 HBM 64GB**(16 卡/节点 = A3/910C 形态;用户口径"这是 A3"。具体型号 910B/910C 以步骤 2 全量 `npu-smi info` + 用户确认为准,勿套用 A5/950 参数)
- 共享存储 `/mnt/sfs_turbo`(SFS Turbo 1.2T)4 节点全部挂载;**模型权重在 `/mnt/sfs_turbo/models/`**,当前有 `GLM-5.3-w4a8-int`(W4A8 量化版 → 部署时需 `--quantization ascend` 类参数,权重目录应有 `quant_model_description.json`,pd.sh 启动前自动交叉校验)
- **每节点独立数据盘 `/dev/sdb1`(984G)挂 `/data`**——权重运行时暂存首选(常驻、重启不丢);根盘只有 196G 放不下大权重(查余量务必 df -h 看全部挂载点)
- 4 节点同一套 root 密码(凭据文件),节点间未配免密(BatchMode ssh 失败)
- **外网能力**: 仅 .98(<CLUSTER-EIP>)有外网出口,且到 quay.io 的 blob CDN(Akamai)**间歇不可达**(镜像拉取方案见 troubleshooting 第〇节);内网 3 台无外网,镜像一律经 .98 `docker save` → SFS → 各节点 `docker load`
- **内部镜像源**: `swr.cn-southwest-2.myhuaweicloud.com/<team-org>/`(用户团队自建,国内直达;注意其中的 `6.5.938-*:glm5.3-*` 是训练/量化底座镜像——conda PyTorch-2.10.0,无 vllm,不能当推理镜像)

**16 卡注意**: Mooncake KV 端口下限 = 20000+16×1000 = **36000**,`KV_PORT_BASE` 建议 **36100** 起步;TP 档位按 A3 取 2/4/6/8/16。

## 凭据文件格式(默认 `C:\Users\Administrator\Desktop\<cred-dir>\机器信息.txt`)

```
第 1 行: 跳板 EIP          (<CLUSTER-EIP>)
第 2 行: 用户名            (root)
第 3 行: 密码              (敏感,只由脚本读取)
第 4 行起: 每行一个节点内网 IP
```

`scripts/cluster_ssh.ps1` 默认解析该文件;`-CredFile` 可指向其他同格式文件。

## 数据面/控制面分工(2026-11-17 实战定型,优先用共享存储)

- **数据面一律走 SFS(NFS 共享)**: 脚本、config、镜像 tar、权重正本——写一次全节点可见,**节点间零 SFTP/拷贝**;4 节点内网互通但未配免密 ssh,跨节点传文件不要走 ssh,一律落 SFS。
- **控制面才用 SSH(隧道)**: "在节点上执行命令/起容器"这一动作,文件共享替代不了;控制点(Windows)在集群外,内网节点经入口隧道下发。节点间配好免密后控制面也可内网直连。
- **唯一例外**: 大权重**运行时读缓存**走每节点 /dev/shm(SFS 直读在 MoE/EP 多 worker 下病理级慢,见 troubleshooting 权重加载条)。

## 访问通道(2026-11-17 实测定型)

**实测结论**: Windows 控制机**只能直达** `<CLUSTER-EIP>`(即节点 .98 的 EIP);其余内网 IP 22 端口不可达(Test-NetConnection 失败)。`scripts/cluster_ssh.ps1` 已内置两级通道,全自动:

1. **EIP 直连**: 目标为 `<CLUSTER-EIP>` 或其他公网地址 → Posh-SSH 直连。
2. **SSH 本地端口转发隧道**(内网节点,实测 .28/.55/.181 全通): 经入口节点会话建 `127.0.0.1:22<末段> → 节点:22` 转发(Posh-SSH `New-SSHLocalPortForward`,New 即启动),再对隧道端口发起 SSH/SFTP。**全程密码认证,无需节点间免密/sshpass**。

用法:
```powershell
scripts/cluster_ssh.ps1 -Command 'npu-smi info | head -5'                              # 全部 4 节点
scripts/cluster_ssh.ps1 -Nodes <NODE1-IP>,<NODE2-IP> -Command 'docker ps'
scripts/cluster_ssh.ps1 -Nodes <NODE1-IP> -Push .\config.env:/root/deploy/config.env  # 推文件
scripts/cluster_ssh.ps1 -Nodes <NODE1-IP> -ScriptFile .\pd.sh -RemoteDir /root/deploy # 上传+chmod+bash -n
scripts/cluster_ssh.ps1 -Nodes <NODE1-IP> -Get /tmp/out.log:$env:TEMP\out.log         # 取文件
scripts/cluster_ssh.ps1 -JumpCommand 'df -h /mnt/sfs_turbo'                            # 只在入口节点执行
```

若某日内网密码与入口不同(当前实测相同),隧道连接会报认证失败——届时用 -CredFile 指向按节点区分的凭据文件或向用户索取。

## 端口规划(PD 形式默认值)

| 用途 | 端口 | 说明 |
|------|------|------|
| Proxy 入口(API) | 8000 | 客户端唯一入口,Proxy 节点 |
| Prefill HTTP | 8100 | 每个 Prefill 节点(不同主机,同端口不冲突,host 网络) |
| Decode HTTP | 8200 | 每个 Decode 节点 |
| Mooncake KV | 36000 + engine_id×10 | engine_id: Prefill-i → i;Decode-j → x+j(x=Prefill 数)。**须 ≥28000** |
| Ray(multi_node) | 6379 / 8265 | head 节点 |
| Transfer Engine 动态 | 20000~27999(8 卡) | KV 端口规划避开此范围的原因 |

节点间防火墙/安全组需放通: 上表全部端口 + HCCL 数据面(跨节点 NPU 通信,见 troubleshooting)。

## 已知环境特性

- 历史同类集群(道通 A5,950DT)的实操记录在 `Desktop\道通A5\`(Mooncake-PD-Qwen3.8-27B / DeepSeek-V4.1-Flash 部署指南),本 skill 模板即从该实践提炼;新集群参数以步骤 0 实测为准。
- 集群内网请求注意 `--noproxy '*'`(节点/跳板可能配置了全局 HTTP 代理环境变量)。
