# ModelArts AscendCloud 高可用部署模式(RouteServer HA)

> **备注**: 本模式依据华为云官方《GLM 5.3 基于轻量算力节点 Snt9b23 的高可用部署实践指导(6.5.938)》+ 2026-11-18 实测部署整理;适用"从版本包现场构建镜像 + RouteServer 高可用 3P1D"场景。与 `modelarts-deploy.md`(CreateInferService 在线服务)是两种不同的 MA 载体。

## 适用与判定

- 用户给/提到 **AscendCloud-6.5.938 版本包 + 实践指导文档**,要求"按版本包和指导文档部署、MA 方式、不能用现有镜像"→ 本模式
- 特征: RouteServer 高可用架构(ETCD 选主 + Mooncake Master APC),vLLM 0.23.0 配套,推理(非训练)

## 版本配套(6.5.938,推理)

| 项 | 值 |
|----|----|
| vLLM-Ascend / vLLM | release/0.23.0 / 0.23.0 |
| CANN / 驱动 / PyTorch / Python | 9.1.0 / 25.5.1 / 2.10.0.post6 / 3.12.13 |
| 基础镜像(贵阳一) | `swr.cn-southwest-2.myhuaweicloud.com/atelier/pytorch_ascend:pytorch_2.10.0-cann_9.1.0-py_3.12-hce_3.0.2603.2-aarch64-snt9b23-20260808171933-4dd3fef` |
| 业务镜像 | 基础镜像 + AscendCloud 版本包现场构建 |
| 权重 | ModelScope `MA-AI/GLM-5.3-w4a8-int`(W4A8,`--quantization ascend`) |

## 六种 Role 与最小数量(测试/生产)

| Role | 功能 | 测试最少 | 端口 | NPU |
|------|------|---------|------|-----|
| RouteServer Workers | 对外 HTTP API 入口 | 1 | 19800 | 否 |
| RouteServer Candidates | 选主(经 ETCD)/地址管理/集中调度 | 1 | 19802 | 否 |
| ETCDs | 选举+实例状态存储(**至少 3 实例反亲和,禁跨 RS 集群共用**) | 3 | 32379/32380 | 否 |
| Prefills | PD 预填充 | 按拓扑 | 9081+ | 是 |
| Decodes | PD 解码 | 按拓扑 | 9900+ | 是 |
| Mooncake masters | APC 前缀缓存调度(经 ETCD 选主) | 1 | 52050/52052 | 否 |

## 镜像构建(指导文档第 3 章)

```bash
# 构建机需 docker + 外网;git 源是华为 GitCode(国内可达,build.sh 内置 token),非 GitHub
git config --global http.version HTTP/1.1            # 指导文档要求的防 HTTP/2 中断
export BASE_IMAGE=<上表基础镜像>                      # 从 SWR 拉,~23.7GB,国内快
export BUILD_IMAGE_NAME=glm53-ma:6.5.938-a3
export IMAGE_TYPE=A3                                  # A2/A3/A5 三选一,按实际芯片(决定 cloud-turbo-ops 子包)
unzip AscendCloud-*.zip -d ./AscendCloud/
unzip ./AscendCloud/CANN-cloud-turbo-ops-*-${IMAGE_TYPE}-*.zip -d ./AscendCloud/cloud_turbo_ops/
unzip ./AscendCloud/AscendCloud-LLM*.zip -d ./AscendCloud/AscendCloud-LLM
cp ./AscendCloud/AscendCloud-LLM/llm_inference/build.sh ./
sh build.sh   # clone vllm-cloud(GitCode)→ checkout version.info 版本 → build_image.sh(pip+算子编译+openssl 等,全程 40~90 分钟)
```

实测记录(2026-11-18, .98 构建): 全程约 ~70 分钟;算子编译目标 `ascend910_93`(A3)正确;pip 走华为云镜像;无 GitCode 网络问题。

## 部署顺序(指导文档第 4 章,强制顺序)

0. **宿主机准备(仅 P 节点)**: 大页 `echo 576717 > /proc/sys/vm/nr_hugepages`(1.1TB,mooncake KV 暂存用)+ `sysctl -w net.ipv4.tcp_syn_retries=2`;停残留 `pkill -9 vllm` 等;清 `kernel_meta`/`extra-info`
1. **创建容器**(每 Role 一个,`--shm-size=500g --net=host --privileged`,挂 `/data:/data` **不挂 /home/ma-user**,driver+npu-smi 同挂)
2. **ETCD ×3**(3 台机器,`start_etcd.sh`,data/log 放 /data)→ `etcdctl endpoint status` 验证
3. **RS Candidate**(19802)→ `/status` 200;**RS Worker**(19800)
4. **Mooncake Master**(52050/52052,ETCD 端点用**分号**分隔)→ `curl :52052/get_all_keys` 200
5. **P ×3**(容器内 `run_p.sh`)→ 各 9081/9082 health 200
6. **D ×1**(`run_d.sh`)→ 9900-9907 health 200
7. **注册**: `rs_instance_join.py` P(ips×3, ports=9081×3, nums=2,2,2)+ D(ip×1, port=9900, num=8)→ `/status` 全 running
8. **测试**: `curl http://<worker_ip>:19800/v1/chat/completions`(model=glm-53;不支持 /v1/completions;reasoning 字段;256 并发限流 429)

## 3P1D 拓扑实例(16 卡/节点 × 4,实测参数)

- P(.98/.28/.55): TP8 × DP本地2 = 16 卡,全局 PREFILL_DP=**6**,DP_RANK_START=**0/2/4**,DP_ADDRESS=P 主节点,VLLM_PORT 9081-9082,KV_PORT 14580,ENGINE_ID=0,P 侧 KV=**MultiConnector**(MooncakeV1 producer + AscendStore),MTP 1 token,enforce-eager,P prefix-caching 开
- D(.181): TP2 × DP本地8 = 16 卡,全局 DECODE_DP=**8**,VLLM_PORT 9900-9907,ENGINE_ID=1,D 侧 KV=**单层 MooncakeConnectorV1 consumer**(kv_load_failure_policy fail),MTP 3 token,图模式 FULL_DECODE_ONLY,prefix-caching 关
- KV_CONFIG 两侧 prefill/decode 字段完全一致(描述全集群拓扑): prefill {dp:6,tp:8} / decode {dp:8,tp:2}
- 权重路径容器内 `/data/glm53`(每节点 /data 盘,SFS 正本分发;容器只挂 /data)

## 关键差异与坑(2026-11-18 实测,血泪全集)

- **指导文档脚本默认值**(PREFILL_DP=4/DECODE_DP=16)对应"2P2D 的 8 卡机"拓扑,**必须按自己集群改**;3P1D×16 卡见上表
- mooncake master 的 ETCD 端点分隔符是**分号**,RS/etcdctl 用逗号
- RS Worker readiness: `--readiness-cfg "prefill:1#decode:1"`(至少 1P1D 健康才接流)
- 客户端打 **Worker 端口 19800**(不是 P/D 端口);max_tokens=1 时 APC 不命中
- **openssl 三方冲突(必踩)**: 环境里有三套 crypto(系统 /usr/lib64(HCE 带 EVP_md2)、conda 3.6(无 EVP_md2, 有 3.4+ 符号)、seccomponent 目录)。症状二选一: `libldap.so.2: undefined symbol EVP_md2@OPENSSL_3.0.0`(mooncake/engine 导入崩)或 `_hashlib: version OPENSSL_3.4.0 not found`。**解法(实测通过)**: 编译 EVP_md2 空垫片 `echo 'void* EVP_md2(void){return 0;}' | gcc -shared -fPIC -o /usr/local/lib/libmd2shim.so -` + `LD_PRELOAD=libmd2shim.so:conda/libssl.so.3:conda/libcrypto.so.3:libjemalloc.so.2`(垫片满足 libldap 加载期符号解析, conda crypto 满足 python)。**注意**: 只预加载系统 crypto 会反向弄死 conda _hashlib;LD_LIBRARY_PATH 重排无效(python 进程内已加载同名 soname 优先)
- **引擎握手 5 分钟硬编码**: `vllm/v1/engine/core.py` 的 `HANDSHAKE_TIMEOUT_MINS = 5`(无 env 可调);390GB 权重从 /data 盘加载(16 个 EP worker 各自遍历分片)必然超 5 分钟 → `RuntimeError: Did not receive response from front-end process within 5 minutes` → APIServer 连锁退出且**表象是静默暴毙(输出被 >/dev/null 吞)**。**解法**: 容器内 sed 补丁改 60:`sed -i "s/^HANDSHAKE_TIMEOUT_MINS = 5/HANDSHAKE_TIMEOUT_MINS = 60/" <vllm路径>/vllm/v1/engine/core.py` + `VLLM_ENGINE_READY_TIMEOUT_S=3600` + 启动前后台 `cat 权重目录/*.safetensors >/dev/null` 预热页缓存
- **pkill 大小写陷阱(连环暴毙元凶)**: vllm 子进程名是**大写** `VLLM::EngineCore/Worker/DPCoordinator`——`pkill -f "vll[m]"` 杀不到它们,残留 EngineCore/DPCoordinator 端口占着,新一轮引擎莫名互踩。**每次重启必须双杀**: `pkill -9 -f "vll[m]"; pkill -9 -f "VLL[M]::"`
- **并行部署冲突(最高优先检查)**: 动手前先 `docker ps` 看**是否有别人的同类容器**(本次实测: 同事同名方案 prefill-0/1/2+decode-0 四节点并行,同抢 16 卡/9081/16591/32379 → 双方引擎随机暴毙、极难定位)。发现即停手协调,`docker ps` 过滤自己命名前缀,只动自己的容器
- **mooncake master 选主震荡(未解决)**: 3 实例均 candidate↔standby 每秒震荡不选主(etcd 连接正常、无 W/E 日志);单机模式(-enable_ha 去掉)同样震荡。P↔D 直连用 use_ascend_direct 不依赖 master,仅 APC 前缀缓存受影响——可先绕过,待解
- **诊断工具箱**: py-spy 装宿主机(wheel 走华为 pypi 镜像),**宿主机可直抓容器内进程**(同内核 pid 可见)——EngineCore 卡 `wait_for_ready`、Worker 卡 `safetensors_weights_iterator` 一目了然;引擎"遗言"要靠前台重定向跑(脚本里 `> /dev/null 2>&1 &` 改 `>> /tmp/eng.log 2>&1`),run.log 里没有 worker 级堆栈
- 镜像构建全程 ~70 分钟(算子编译 ascend910_93 即 A3 目标);gitcode.com 源国内直达无障碍
- P 宿主机 1.1TB 大页(`echo 576717 > /proc/sys/vm/nr_hugepages`)对退出/让位场景**保留不释放**(同方案部署都需要)
