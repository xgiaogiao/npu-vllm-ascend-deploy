# Mooncake PD 分离实战笔记(裸机容器)

来源: 本环境 950DT 集群上 Qwen3.8-27B 与 DeepSeek-V4.1-Flash 的 Mooncake PD 双机部署实践 + vllm-ascend 官方 PD 文档,提炼进 `templates/pd.sh`。

## 一、拓扑与端口

```
客户端 → Proxy(Proxy 节点 :8000,不占 NPU)
            ├→ Prefill-0 (:8100)  engine_id=0 kv=36000
            ├→ Prefill-1 (:8100)  engine_id=1 kv=36010   ← 3P1D 示例
            ├→ Prefill-2 (:8100)  engine_id=2 kv=36020
            └→ Decode-0 (:8200)   engine_id=3 kv=36030
                 ↑ P ── Mooncake KV 传输(A5 走 UB 超平面)── D
```

- 每节点 1 个独立引擎(host 网络),HTTP 端口按角色固定(P=8100/D=8200),不同主机不冲突。
- engine_id 全局唯一(Prefill-i → i,Decode-j → x+j),kv_port = KV_PORT_BASE + engine_id×10。**kv_port 下限按实际卡数推导**(官网 F4: Mooncake AscendDirectTransport 随机端口范围 [20000, 20000+卡数×1000)): 8 卡 → ≥28000;**16 卡(A3 单节点 16 卡)→ ≥36000**,此时 KV_PORT_BASE=36000 恰在边界,建议直接用 36100 起步更稳妥。
- Proxy 是镜像自带联调示例(`load_balance_proxy_server_example.py`),无鉴权/TLS/高可用,只监听 0.0.0.0:PORT,`--prefiller-hosts/--decoder-hosts` 逗号分隔多实例。

## 二、kv-transfer-config 两种连接器

| 连接器 | 出现版本/镜像 | engine_id | 典型场景 |
|--------|----------------|-----------|----------|
| `MooncakeHybridConnector` | 模型名 tag 镜像(qwen3.8-a5 等) | **必填**(字符串 "0"/"1"/…) | 混合注意力(linear+full attention)模型,Qwen3.8/DeepSeek V4.1 实测 |
| `MooncakeConnectorV1` | 较新 vllm-ascend | 无此字段,靠 kv_port 区分 | ModelArts GLM-5.3 PD 记录使用;kv_buffer_device="npu" |

**以模型文档/镜像内实际可用连接器为准**(容器内 `python3 -c "import vllm_ascend.distributed.kv_transfer.kv_p2p.mooncake_hybrid_connector"` 验证)。pd.sh 的 `KV_CONNECTOR` 配置项二选一,extra_config 生成规则相同:

```json
{
  "kv_connector": "MooncakeHybridConnector",
  "kv_role": "kv_producer",            // decode 侧 kv_consumer
  "kv_port": 36000,                     // 本引擎端口(见上规划)
  "engine_id": "0",                     // MooncakeConnectorV1 无此字段
  "kv_connector_extra_config": {
    "prefill": {"dp_size": <PREFILL_DP_LOCAL>, "tp_size": <TP_SIZE>},
    "decode":  {"dp_size": <DECODE_DP_LOCAL>, "tp_size": <TP_SIZE>}
  }
}
```

extra_config 描述**两侧各自引擎的并行布局**,必须与两侧实际 `--tensor-parallel-size` / `--data-parallel-size(-local)` 一致;硬编码 1/1 在 TP>1 或 DP>1 时报 pydantic `conflicting tensor/data parallel size`。节点内多 DP rank 时 vLLM 自动派生子 engine_id,基础 engine_id 仍按上述规划填。

## 三、A5/950 UB 通信: hixlep(跨节点 PD 必需)

P↔D KV 经 UB 链路传输时 vllm-ascend 读 `/etc/hixlep/ub_endpoint_npu_*.json`。宿主机已有(`/etc/hixlep` 非空)则只读挂载进容器;缺失时 pd.sh 用 skill 内置 `scripts/a5_hixlep/` 离线包在容器内生成(MooncakeConnectorV1 场景另经 `ascend_local_comm_res_path` 指向):

1. `/etc/hccl_rootinfo.json` 缺失 → 离线安装 `unofficial_ascend_tools` wheel → `mindcluster-tools rootinfo --product_type server --output /etc/hccl_rootinfo.json`(**注意 console script 名是 `mindcluster-tools`,不是 python -m mindcluster_tools**)
2. rootinfo 的 `rank_list[].local_id` 可能是 48-55/8-15 而 route.conf dev_id 是 0-7 → 按 rank_list 索引重排 local_id=0..N-1(复制到 /tmp 改,容器内 /etc 可能只读)
3. `/lib/route.conf` 缺失 → `gen_route.sh` 生成(读 /proc/ascend_ub 驱动接口,需 HDK 驱动)
4. `generate_ep.py --local --server --rootinfo-path <调整后> --route-path /lib/route.conf --topo-path <rootinfo 内 topo_file_path> --output-dir /etc/hixlep`
5. `fix_ub_endpoint.py -y` 修正 NPU ID ↔ Chip Phy-ID 文件名错位(用 `npu-smi info -m` 映射)
6. 多机 net_instance_id 必须一致(不一致 UB 建链失败,脚本会 WARN)

A2/A3 走 RoCE 不需要以上步骤。

## 四、容器运行时挂载清单(pd.sh 已内置,排障时逐项核对)

设备(--device): `/dev/davinci{0..7}` `/dev/davinci_manager` `/dev/hisi_hdc` `/dev/ummu` `/dev/uburma`(存在才加,含 `/dev/infiniband`)
只读挂载(-v :ro): `/usr/local/Ascend/driver` `/etc/ascend_install.info` `/etc/hccl_rootinfo.json` `/etc/cloud/topo` `/etc/hccn.conf` `/etc/libibverbs.d/hrn5.driver` `/etc/hixlep` `/usr/local/dcmi` `/usr/bin/urma_admin` `npu-smi` 实际路径 + `$MODEL_PATH`
条件挂载: `/usr/lib64/libhrn5-rdmav34.so → /usr/lib/aarch64-linux-gnu/libibverbs/libhrn5-rdmav34.so`、`libibv_extend.so.4.2.0 → libibv_extend.so.4`(RDMA 驱动库版本匹配,缺失致 HCCL error code 4)
环境变量: `VLLM_HOST_IP`/`HCCL_IF_IP`=本机IP;`GLOO_SOCKET_IFNAME`/`TP_SOCKET_IFNAME`/`HCCL_SOCKET_IFNAME`=本机业务网卡;`HCCL_BUFFSIZE`(MoE 见 troubleshooting);`PYTORCH_NPU_ALLOC_CONF=expandable_segments:True`;A5 另需 `ASCEND_LOCAL_COMM_RES={"version":"1.3"}`(容器内无 hixl 自动生成功能时的兜底)
网络: `--network host`(必须,HCCL/KV 直连);`--shm-size 1g`;`--restart unless-stopped`

## 五、启动顺序与验证(重申)

1. 全部 Prefill 启动 → **逐台** `curl http://<P_IP>:8100/health` 200(首次 10~20 分钟)
2. 全部 Decode 启动 → 逐台 200
3. **最后** Proxy(`./pd.sh proxy`)
4. 端到端请求**必须经 Proxy**;同时看三侧日志确认 KV 传输无报错(仅 /health 200 不证明 PD 链路可用)
5. 停机反向: 先 Proxy 后 D 再 P

## 附录: 权重完整性校验脚本(步骤 1 用,写 /tmp 执行)

```bash
python3 - "$MODEL_PATH" <<'PY_CHECK'
import json, os, struct, sys
from pathlib import Path
root = Path(sys.argv[1])
assert (root / 'config.json').is_file(), '缺少 config.json'
index = json.loads((root / 'model.safetensors.index.json').read_text())
names = sorted(set(index['weight_map'].values()))
total = 0
for name in names:
    path = root / name
    with path.open('rb') as f:
        raw = f.read(8)
        assert len(raw) == 8, f'{name}: 文件头不完整'
        size = struct.unpack('<Q', raw)[0]
        assert 0 < size < 16 * 1024 * 1024, f'{name}: 文件头长度异常'
        header = json.loads(f.read(size))
    end = max(v['data_offsets'][1] for k, v in header.items() if k != '__metadata__')
    assert os.path.getsize(path) == 8 + size + end, f'{name}: 文件未下载完整'
    total += end
assert total == int(index['metadata']['total_size']), '权重张量总大小不匹配'
print(f'模型文件检查通过：{len(names)} 个权重分片，{total} 字节张量数据')
PY_CHECK
```
