# 实战案例库(v1.0)

本 skill 的方法与参数全部来自以下实测部署。**换模型/集群时,先在这里找最接近的案例作起点**;案例中的拓扑参数、端口、启动参数经过端到端验证,可显著缩短新部署的试错路径。

## 案例总览

| # | 时间 | 集群 | 模型 | 模式 | 拓扑 | 结果 |
|---|------|------|------|------|------|------|
| 1 | 2026-10 | 道通 A5(2×950DT 8卡,<A5-NODE1-IP>/.82) | Qwen3.8-27B BF16 | 裸机 1P1D Mooncake PD | 两侧各 TP8/DP1 | ✅ 端到端验证 |
| 2 | 2026-10 | 道通 A5(同上) | DeepSeek-V4.1-Flash(W8A8 fp8) | 裸机 1P1D Mooncake PD | 两侧各 TP1×DP8 + EP + `--quantization deepseek_v4_fp8` | ✅ 端到端+压测 |
| 3 | 2026-11-17 | 华为云 4×A3(16×Ascend910 64GB,<NODE-SUBNET>.x) | GLM-5.3 W4A8-int | 裸机 3P1D(quay v0.30.0-a3) | P: TP1/PCP16/PP1×3节点; D: TP2×DP8 | ✅ 端到端验证 |
| 4 | 2026-11-18 | 同上 | GLM-5.3 W4A8-int | MA-AscendCloud HA(6.5.938 从零构建) | P: TP8×DP本地2×3; D: TP2×DP8 + RS/ETCD/Mooncake | ⏸ 至 MoE 装载(并行冲突让位),前 4 补丁已闭环 |

## 案例要点速查

### 案例 1/2(道通 950DT)— Mooncake 1P1D

- 连接器 `MooncakeHybridConnector`,P=engine_id "0"/kv 36000,D="1"/kv 36100(DeepSeek 用 36010/36020);extra_config 如实描述两侧 {dp,tp}
- Qwen(混合注意力): `--reasoning-parser qwen3`、`--no-enable-prefix-caching`;DeepSeek: `--quantization deepseek_v4_fp8` + `--enable-expert-parallel` + DP8/TP1(节点内 8 DP rank)
- Proxy 用镜像自带 `load_balance_proxy_server_example.py`;DeepSeek 的 proxy 探活端点是 **`/healthcheck`**(与 /health 不同)
- 容器优雅停: `docker stop -t 60`(PD 大模型直接 stop 会掐断 KV 传输,给 60s 宽限)
- 950DT 容器挂载: davinci0-7/manager/hisi_hdc/ummu/uburma + driver/ascend_install.info/hccl_rootinfo/**hixlep**/sbin/dcmi/npu-smi/urma_admin(全套见 mooncake-pd-notes)
- 验证: verify.py 中文问答 + verify-stream.py 长输入流式双验

### 案例 3(GLM-5.3 裸机 3P1D)— 本 skill 主验证案例

详见 `troubleshooting.md` 与 `mooncake-pd-notes.md`;关键: 换源拉镜像(fast_pull2)、权重三级暂存(/data 391GB×4)、decode 关 static/super kernel(AclskOptimize 500001)、RAM 加载 14s vs SFS 37min/分片。

### 案例 4(MA-AscendCloud)— 四补丁 + 文档解析流水线

详见 `modelarts-ascendcloud-ha.md`;镜像 `glm53-ma:6.5.938-a3` 从 atelier 基础镜像+版本包构建成功,ETCD/RS/Mooncake 全绿。

## 压测方法库(步骤 7 进阶)

### acs-bench(华为官方,AscendCloud/MA 镜像内置)

```bash
# 1) 造随机数据集(按服务端 tokenizer)
acs-bench generate dataset --tokenizer <MODEL_PATH> --dataset-type random \
  --output-path ./built_in_dataset --input-length 2048 --num-requests 3000
# 2) 阶梯并发压测(1→512 逐级,threading-pool + openai-chat,warmup 1)
acs-bench prof --provider ./providers.yaml --dataset-type custom \
  --input-path ./built_in_dataset/ --concurrency-backend threading-pool \
  --backend openai-chat --warmup 1 --epochs 1 \
  --num-requests 10,20,40,80,160,320,640,1280,2560,5120 \
  --concurrency 1,2,4,8,16,32,64,128,256,512 \
  --input-length 2048 --output-length 1024 --benchmark-save-path ./output/
```
压测容器与被测服务同规格挂载(950DT 挂载清单同上);PD 分离下压测端点打 **Proxy**。

### vllm bench serve(镜像自带,免装)

`docker exec <P容器> vllm bench serve --model <name> --base-url http://<proxy>/v1 --dataset-name random --random-input-len 2048 --random-output-len 256 --num-prompts 100 --request-rate 5 --tokenizer <MODEL_PATH>`

## 宿主机(非容器)CANN 环境准备 SOP

容器模式不需要本节;仅当在宿主机直装推理栈(如压测机/边缘场景)使用:

```bash
# oepkgs 昇腾源 + 组件安装
sudo curl https://repo.oepkgs.net/ascend/cann/ascend.repo -o /etc/yum.repos.d/ascend.repo && yum makecache
sudo yum install -y python3 python3-pip
sudo yum install Ascend-cann-toolkit-9.1.0          # 按目标 CANN 版本
sudo yum install Ascend-cann-950-ops-9.1.0          # 950 系列算子包(950 集群用)
sudo yum install Ascend-cann-nnal-9.1.0             # NNAL/ATB 加速库(对应容器内 /usr/local/Ascend/nnal)
source /usr/local/Ascend/cann/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh        # ATB 环境(漏 source = libatb.so 加载失败,同容器坑)
# 验证
python3 -c "import acl;print(acl.get_soc_name())"   # 返回芯片型号即 OK
npu-smi info -t board -i 1 | egrep -i "software|firmware"   # 核对固件版本配套
# 已知坑: superkernel 0.1.0 的 pip 依赖(decorator/numpy/psutil/scipy)不会自动装齐,需手动补
```
