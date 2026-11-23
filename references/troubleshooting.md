# 裸机容器部署排障手册

按"现象 → 根因 → 处理"组织;含本环境集群实测记录(标注"实测")。

## 〇、镜像拉取(2026-11-17 实战,最高频卡点)

### docker pull 卡 `Retrying` / `TLS handshake timeout`,manifest 能拉、层下不动

- **根因(实测)**: quay.io 的 manifest/auth 走 quay.io 本体(可达),**blob 层 307 重定向到 `cdn01.quay.io`(Akamai CDN)**——华为云该区域出口到 Akamai **间歇性不可达**(时好时坏,同一节点有人手动拉成功、脚本拉卡死);内网节点(.28/.55/.181)**完全无外网**,只能靠入口节点分发。
- **诊断三板斧**(在入口节点):
  ```bash
  curl -sk -o /dev/null -w "%{http_code}\n" https://quay.io/v2/          # 通(401)
  curl -sk -o /dev/null -w "%{redirect_url}\n" -H "Authorization: Bearer $TOKEN" \
    https://quay.io/v2/ascend/vllm-ascend/blobs/<digest>                  # 看 307 目标 = cdn01.quay.io
  curl -vk --max-time 15 https://cdn01.quay.io/ 2>&1 | grep -E "Connected|timed out|refused"  # 死/活
  ```
- **解决(按优先级)**:
  1. **内部 SWR 镜像**(最快): 用户团队自建仓库(实测本集群存在 `swr.cn-southwest-2.myhuaweicloud.com/<team-org>/...`),国内直达,先问用户;
  2. **公共换源 + `scripts/fast_pull2.sh` 多源强制拉取**(2026-11-17 实测成功): 实测可用的 quay 匿名代理源 **`quay.hlmirror.com`**(manifest 匿名 200、blob 支持 Range 206,单连接 ~0.6MB/s,并发 ~2MB/s);`quay.m.daocloud.io` 活但匿名 401(需 token 握手,未深究);`quay.aityp.com` 403;`docker.1ms.run` 是 DockerHub 源不含 quay;**Docker Hub 上没有 ascend/vllm-ascend**。fast_pull2: 每段请求在源列表(hlmirror → quay 直连)间轮换 + 并发 10 段 + `--speed-limit 30000 --speed-time 25` 卡速自断 + 签名 token 后台刷新(注意: 自定义函数要 `export -f`,漏了会退化为单源——已修);产物直接 `docker load`;
  3. **有外网带宽的中转机**: `docker pull` + `docker save` → 传 SFS → 各节点 `docker load`(注意中转机自身带宽,实测 1MB/s 的机器传 8.2GB 不现实);
  4. `/etc/hosts` 锁定 `quay.io` IP 仅对 manifest 有效(重定向域是 cdn01.quay.io,不受影响),别白忙。
- **入口节点带宽被下载打满时 SSH 会超时**——这是正常现象(下载占满 EIP),等一会重连即可,不要误判节点故障。
- **分发到无外网节点**: 入口节点 `docker save -o /mnt/sfs_turbo/deploy/<img>.tar <IMAGE>`(SFS 共享)→ 各节点 `docker load -i`,无需节点间 ssh/凭据。

### 本次实战其他坑(必看)

| 坑 | 现象 | 处理 |
|----|------|------|
| `$( [[ ]] && )` 静默死 | `set -e` 下 `args+=(-v "$p:$p"$( [[ cond ]] && echo x ))` 条件为假时命令替换返回 1,**脚本无任何输出直接退出**(实测 start.sh 挂载循环) | 条件为假的替换必须兜底: `$( [[ cond ]] && echo x \|\| true )`,或改为独立 if/变量拼接;算术里出现字符串(如 `$(( ROLE == decode ? ... ))`)在 set -u 下报 unbound variable,同样改 if |
| **pkill 大小写陷阱** | vllm 子进程名为大写 `VLLM::EngineCore` 等,`pkill -f "vll[m]"` 杀不到;残留进程占端口 → 新引擎随机暴毙(实测 MA 部署连环故障元凶之一) | 重启前双杀: `pkill -9 -f "vll[m]"; pkill -9 -f "VLL[M]::"` |
| **并行部署冲突** | 同集群有他人同类部署(容器名/端口/卡全冲突),双方引擎随机静默死、极难定位(实测: 同事同方案四节点并行) | 动手前 `docker ps` 查全量容器;只动自己命名前缀的容器;发现冲突立即停手找用户协调 |
| pkill 自杀 | `pkill -f "docker pull"` 把含该字面量的 ssh 包装 shell 一起杀,命令无输出退出 | 模式加括号 `pkill -f "docker pul[l]"`,且**不要与含目标字面量的命令写同一条**(如 nohup 路径里就有它)——彻底拆成两次调用 |
| /etc/hosts 追加拼接 | 原文件无结尾换行时 `echo >> ip 域名` 拼到上一行,两条全废 | 先 `grep -v "<条目>" /etc/hosts > /tmp/h; printf "ip 域名\n" >> /tmp/h; cp /tmp/h /etc/hosts` |
| PS1 脚本中文乱码致解析失败 | 无 BOM 的 UTF-8 被 PS 5.1 当 ANSI 读,中文字符串报"missing terminator" | 写完立刻转 UTF-8 **with BOM**:`[IO.File]::WriteAllText($p,$raw,[Text.UTF8Encoding]::new($true))` |
| PowerShell 5.1 无 `&&` | 命令报 The token '&&' is not valid | 用 `;` 或 `if ($?) {}` |
| docker save/load 边界 | tar 放节点本地盘(196G 够)或 SFS(770G 够)均可,SFS 全节点共享免 scp | 大 tar 落 SFS: `/mnt/sfs_turbo/deploy/` |

## 一、启动阶段

| 现象 | 根因 | 处理 |
|------|------|------|
| `docker: permission denied` / Cannot access Docker daemon | 非 root 或 docker 服务未起 | root 终端执行;`systemctl status docker`;检查 docker 组 |
| `Image ... missing` | 节点未导入镜像 | 每节点 `docker images` 核对;离线 `docker load`;多节点用 digest 固定同一内容 |
| `OSError: Repo id must be in the form ...` | `MODEL_PATH` 挂载路径错/无 `config.json`,本地路径被当 HF repo id | 核对 `-v` 挂载与 `MODEL_PATH` 一致;`ls $MODEL_PATH/config.json` |
| 权重加载中断/文件头不完整 | SFS 上的权重分片不完整(下载中断) | 跑 mooncake-pd-notes.md 附录校验脚本;重新下载缺失分片 |
| `Transformers does not recognize this architecture`(如 `glm5_next`) | 镜像内 transformers 过旧,不识别实验性新架构;文档版本高于稳定镜像 tag(实测 GLM-5.3-Flash: 文档 v0.30.0RC vs quay 稳定 v0.23.0) | `docker run --rm <IMAGE> python3 -c 'import transformers;print(transformers.__version__)'` 确认;换团队内部镜像(tag 常直接叫模型名)或换稳定版本模型 |
| `ValueError: No available memory for the cache blocks`,日志 `Available KV cache memory: -Y GiB` | TP 不满足显存条件,权重占满预留后 KV cache 为负 | 回步骤 2 四条件重算;换更大 TP / 量化权重 / 降 `--max-model-len` |
| `NPU memory insufficient` 运行期 OOM | 旧容器仍占卡 / MAX_MODEL_LEN 过大 | `docker ps` 清旧容器;两侧同步降 `MAX_MODEL_LEN` 重建容器 |
| TP≥8 启动即崩 `NPUModelRunner ... src size=[B,5120] slice size=[B/TP,5120]`(CUDAGraph 捕获阶段) | **混合注意力架构(linear+full 交替,如 Qwen3.8/Qwen3.5 系列)在 TP≥8 时 CUDAGraph 捕获不兼容**(实测;任凭 cudagraph_capture_sizes 取值都崩,文档示例 TP≤4) | `--enforce-eager` 跳过 CUDAGraph(保留 MTP 可用,性能略降);或降 TP=4/2;950DT/950PR 文档推荐 TP=1+DP=8 |
| MoE 建域 `hcclCommInitRootInfoConfig error code 4`(plog `dev_list is NULL`) | **容器内缺/错版 HRN5 RDMA 驱动库**(实测 GLM-5.3 950DT TP8/PP2/EP8) | 挂载宿主机 `/usr/lib64/libhrn5-rdmav34.so` 与 `libibv_extend.so` 进容器(pd.sh 已内置);拷入后须 `ldconfig` 刷新缓存,仅 LD_LIBRARY_PATH 不够 |
| 权重加载成功后 warmup MoE dispatch tiling `errno 561002`(EZ1008),plog `HCCL_BUFFSIZE_EP is too SMALL`(给 NEEDED 公式) | **HCCL_BUFFSIZE 小于 MoE dispatch 通信窗口需求**(actual=2×HCCL_BUFFSIZE;实测 GLM-5.3: 文档值 1200 warmup 崩,1628 通过,保守估算 2415~3255MB) | 按 plog NEEDED 公式调大 `HCCL_BUFFSIZE`(GLM-5.3 建议 ≥1628,留余量 2048);改 config.env 后 **rm 重建容器**(docker start 不生效) |
| `pydantic ... conflicting tensor/data parallel size` | kv_connector_extra_config 的 dp_size/tp_size 与引擎实际并行参数不一致 | extra_config 必须如实反映两侧 `--tensor-parallel-size`/`--data-parallel-size(-local)` |
| Decode 启动即崩 `super_kernel_optimize NPUGraph.cpp:306 AclskOptimize error code 500001`("internal ACL of the system is incorrect") | `additional-config.ascend_compilation_config` 的 `enable_static_kernel:true`/super kernel 与构建/TP 布局不兼容(2026-11-17 实测 A3 TP2 decode;官方 950DT 参考就是显式 false) | 改 `"enable_static_kernel": false, "enable_super_kernel": false`(保留 `enable_npugraph_ex: true`),`docker rm -f` 后重建容器(改配置 docker start 不生效) |
| 卡在 `cpu_binding.py`/`distributed_init` 不动(跨节点) | 通信端口不通 / 网卡绑定错 / master 地址错 | 核对节点间端口放通(安全组/防火墙);`VLLM_HOST_IP`/`HCCL_IF_IP`=本机业务 IP,SOCKET_IFNAME=真实网卡;`ip -4 -brief addr` 核对 |

## 二、PD 分离专项

| 现象 | 根因 | 处理 |
|------|------|------|
| Proxy 起了但请求 5xx/超时 | 后端未就绪就起了 Proxy(顺序错) | 按序重启: 全部 P→health 200→全部 D→health 200→Proxy |
| 两后端 /health 都 200,经 Proxy 请求失败/挂起 | KV 传输未通(仅 HTTP 健康不证明 PD 链路) | 看 P/D 两侧 Mooncake 日志;核对 engine_id 全局唯一、kv_port ≥28000 且互不相同、A5 hixlep 已生成且 net_instance_id 各节点一致 |
| A5 上 hixlep 生成 0 个文件 / `device_id not found` | rootinfo `local_id`(48-55/8-15)与 route.conf dev_id(0-7) 错位 | 按 mooncake-pd-notes.md 第三节第 2/5 步: local_id 重排 + `fix_ub_endpoint.py -y` |
| `ModuleNotFoundError: No module named 'mindcluster_tools'` | wheel 实际包名是 unofficial_ascend_tools | 用 console script: `mindcluster-tools rootinfo ...`(不是 python -m) |
| 跨节点 KV 建链失败,管理 IP 可 ping 通 | UB 数据链路不通(SuperPod 归属/动态端口 20000-27999 未放通) | `npu-smi info -t spod-info -i 0` 核对归属;放通 Transfer Engine 动态端口范围;核对宿主机 urma/uburma 组件 |
| 缺 mooncake 模块 | 镜像不含 Mooncake | 换含 Mooncake 的镜像(模型名 tag);步骤 4 模块自检应提前拦住 |
| 请求被代理转发到外网 | 节点配置了全局 HTTP 代理 | curl 加 `--noproxy '*'`;容器内 unset HTTP_PROXY 等 |
| 内网偶发 `SSL certificate problem`(控制机 curl 文档/镜像仓) | 企业代理 MITM 证书替换 | 白名单内 host 加 `-k`;`-k` 后仍 000 才是真拦截 |

## 三、容器/宿主机层

| 现象 | 根因 | 处理 |
|------|------|------|
| 容器起后秒退 | `docker logs <容器>` 看首错;多数是上述启动类错误 | 对症处理;`--restart unless-stopped` 会循环重启掩盖首错,`docker events`/logs 抓首次输出 |
| 改了 config.env 没生效 | `docker start` 沿用创建时参数 | `./pd.sh stop <role>` + `docker rm <容器>` + 重新 start(rm 重建) |
| PD 容器直接 docker stop 后残留 KV 传输报错 | 默认 10s 宽限掐断 Mooncake 传输 | `docker stop -t 60 <容器>` 优雅停(道通实测);停止顺序: 先 Proxy 后 D 再 P |
| Proxy 探活 404 | 部分镜像的 proxy 示例探活端点是 `/healthcheck` 而非 `/health`(道通 DeepSeek 实测) | 两个都试;`curl http://<proxy>:9000/healthcheck` |
| 端口占用(8000/8100/8200) | 旧单机容器或其他服务残留 | `docker ps` + `ss -lntp` 定位;停旧容器 |
| `NODE_IP not assigned` | config.env 的 NODE_NIC/IP 与本机不符 | `ip -4 -brief addr` 核对;pd.sh 支持自动探测,显式配置时必须逐台正确 |
| SFS 权重加载极慢 | SFS Turbo 是网络存储,首次冷读慢 | 属预期;可在各节点本地盘缓存权重加速重启(牺牲一致性,与用户确认) |
| **SFS 直读权重 + MoE/EP 多 worker = 病理级慢(2026-11-17 实测)** | `Loading safetensors shards: 1/98 [37:33<60:43:48]`——16 个 PCP/EP worker 各自全量读分片,页缓存不生效(prefetch 也没救),SFS 被冗余读打满,预计几十小时 | **决策规则: 起服务后看首分片耗时,>2min/片立即停,改本地暂存**。暂存层级(实测): ①**`/data/<M>`(独立数据盘,首选**——常驻、重启不丢、拷一次终身用;实测每节点 /dev/sdb1 984G 挂 /data。**教训: 排查磁盘余量必须 `df -h` 看全部挂载点,别只看根盘**——本集群根盘 196G 放不下 390G 权重,差点误判"无本地盘"**) ②`/dev/shm`(大内存节点可用,2TB RAM 拷 390GB 后加载 14 秒;但**重启清空**须重拷 90 分钟) ③SFS 直读仅适合小模型/单 worker。脚本实现三级优先: `/data > /dev/shm > SFS`,start.sh 自动缺啥补啥。**为什么不能"拷到 SFS 解决": 权重本来就在 SFS——瓶颈不是放哪,是从哪读;NFS 看得到≠读得快,MoE+EP 多 worker 遍历读会把 NFS 打成 60 小时级**。RAM→/data 本地落盘拷贝极快(~500MB/s,390GB≈13 分钟),远快于 SFS→本地 |
| 多节点行为不一致 | 镜像 tag 同但 digest 不同 / 配置文件不一致 | 固定 digest 拉取;`sha256sum` 比对各节点 config.env 与脚本 |

## 四、验证与调用

| 现象 | 根因 | 处理 |
|------|------|------|
| `/v1/models` 正常但 chat 报 model not found | 请求体 model 字段与 `--served-model-name` 不一致 | 用 `/v1/models` 返回的名字 |
| 首请求超时(>60s) | 大模型首请求含预热/图编译,属正常 | `--max-time 300`;预热后恢复正常即通过 |
| 流式响应中断 | 客户端超时设置过小 | 调大客户端 timeout |
| 推理质量异常(乱码/精度退化) | 量化版权重未带 `--quantization` 参数(BF16 路径跑量化权重) | 核对权重目录 `quant_model_description.json` 与启动参数交叉关系(pd.sh 启动前自动校验) |
