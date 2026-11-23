#!/usr/bin/env bash
# 通用 xPyD PD 分离部署管理脚本(昇腾 NPU 裸机 Docker,芯片无关: A2/A3/310P/950 系列自适应)
# 用法: ./pd.sh check|prefill|decode|proxy|health|test|status|logs|stop|rm|clean [role]
# 角色: prefill / decode / proxy。本机角色由 NODE_IP 在 PREFILL_IPS/DECODE_IPS 中位置自动判定。
# 配置: 同目录 config.env(全节点同一份),取值以 vllm-ascend 模型适配文档 + 已确认部署方案为准。
set -Eeuo pipefail
cd "$(dirname "$0")"

usage() { echo "Usage: $0 check|prefill|decode|proxy|health|test|status|logs <role>|stop <role>|rm <role>|clean" >&2; exit 2; }
action=${1:-}; arg=${2:-}
[[ -n "$action" ]] || usage
[[ -f config.env ]] || { echo "缺少 config.env(参考 templates/config.env.example)" >&2; exit 1; }
# shellcheck disable=SC1091
source ./config.env
: "${IMAGE:?}" "${MODEL_PATH:?}" "${SERVED_MODEL_NAME:?}"
: "${PREFILL_IPS:?}" "${DECODE_IPS:?}" "${PROXY_IP:?}"
: "${PROXY_PORT:=8000}" "${PREFILL_HTTP_PORT:=8100}" "${DECODE_HTTP_PORT:=8200}" "${KV_PORT_BASE:=36000}"
: "${TP_SIZE:=8}" "${PREFILL_DP_LOCAL:=1}" "${DECODE_DP_LOCAL:=1}"
: "${DTYPE:=bfloat16}" "${MAX_MODEL_LEN:=131072}" "${GPU_MEM_UTIL:=0.85}"
: "${MAX_NUM_SEQS:=8}" "${MAX_NUM_BATCHED_TOKENS:=8192}"
: "${KV_CONNECTOR:=MooncakeHybridConnector}" "${HCCL_BUFFSIZE:=512}" "${PREFIX:=vllm-pd}"
COMMON_EXTRA_ARGS=${COMMON_EXTRA_ARGS:-}; PREFILL_EXTRA_ARGS=${PREFILL_EXTRA_ARGS:-}; DECODE_EXTRA_ARGS=${DECODE_EXTRA_ARGS:-}

read -r -a P_IPS <<< "$PREFILL_IPS"; read -r -a D_IPS <<< "$DECODE_IPS"
NP=${#P_IPS[@]}; ND=${#D_IPS[@]}
# IP 格式校验(多 IP 列表必须在 config.env 中整体加引号,否则 sourcing 时会被当命令执行)
for _ip in "${P_IPS[@]}" "${D_IPS[@]}" "$PROXY_IP"; do
  [[ "$_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "config.env IP 非法: '$_ip'(检查 PREFILL_IPS/DECODE_IPS 是否整体加了引号)" >&2; exit 1; }
done

# ---------- 本机 IP / 网卡自动探测 ----------
detect_node_ip() {
  local cand ip
  for cand in "${P_IPS[@]}" "${D_IPS[@]}" "$PROXY_IP"; do
    for ip in $(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1); do
      [[ "$ip" == "$cand" ]] && { echo "$cand"; return 0; }
    done
  done
  return 1
}
NODE_IP=${NODE_IP:-$(detect_node_ip || true)}
[[ -n "${NODE_IP:-}" ]] || { echo "无法探测本机 IP,请在 config.env 显式填 NODE_IP" >&2; exit 1; }
NODE_NIC=${NODE_NIC:-$(ip -4 -o addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')}
[[ -n "${NODE_NIC:-}" ]] || { echo "无法探测 $NODE_IP 所在网卡,请在 config.env 显式填 NODE_NIC" >&2; exit 1; }

# ---------- 角色与 engine_id / kv_port 判定 ----------
role=""; inst=-1; http_port=""; kv_port=0; engine_id=0; kv_role=""
for i in "${!P_IPS[@]}"; do [[ "${P_IPS[$i]}" == "$NODE_IP" ]] && { role=prefill; inst=$i; http_port=$PREFILL_HTTP_PORT; engine_id=$i; kv_role=kv_producer; }; done
if [[ -z "$role" ]]; then
  for j in "${!D_IPS[@]}"; do [[ "${D_IPS[$j]}" == "$NODE_IP" ]] && { role=decode; inst=$j; http_port=$DECODE_HTTP_PORT; engine_id=$((NP + j)); kv_role=kv_consumer; }; done
fi
if [[ -z "$role" && "$NODE_IP" == "$PROXY_IP" ]]; then role=proxy; fi
kv_port=$((KV_PORT_BASE + engine_id * 10))
# 卡数(动态,不写死 8;16 卡 A3 同样适用)与 kv_port 下限校验
NPU_COUNT=$( { ls /dev/davinci[0-9]* 2>/dev/null || true; } | wc -l)
KV_PORT_FLOOR=$((20000 + NPU_COUNT * 1000))
container_for() {
  case "$1" in
    prefill) echo "${PREFIX}-prefill-${inst}" ;;
    decode)  echo "${PREFIX}-decode-${inst}" ;;
    proxy)   echo "${PREFIX}-proxy" ;;
    *) usage ;;
  esac
}

# ---------- 芯片探测(950 系列 PD 跨节点才需要 hixlep/UB;A2/A3 走 RoCE 跳过) ----------
detect_chip() {
  local out
  out=$(npu-smi info 2>/dev/null | head -8) || out=""
  case "$out" in
    *950*) echo 950 ;; *910C*|*"910C"*|*A3*) echo a3 ;; *910B*|*A2*) echo a2 ;; *310P*|*310p*) echo 310p ;;
    *) echo unknown ;;
  esac
}
CHIP=$(detect_chip)
is_950() { [[ "$CHIP" == 950 ]]; }

# ---------- 通用子命令 ----------
case "$action" in
  status) docker ps -a --filter "name=${PREFIX}-"; exit 0 ;;
  logs)   [[ -n "$arg" ]] || usage
          case "$arg" in
            prefill) docker logs -f "${PREFIX}-prefill-$( (for i in "${!P_IPS[@]}"; do [[ "${P_IPS[$i]}" == "$NODE_IP" ]] && echo $i; done) | head -1 )" ;;
            decode)  docker logs -f "${PREFIX}-decode-$( (for j in "${!D_IPS[@]}"; do [[ "${D_IPS[$j]}" == "$NODE_IP" ]] && echo $j; done) | head -1 )" ;;
            proxy)   docker logs -f "${PREFIX}-proxy" ;;
            *) usage ;;
          esac; exit 0 ;;
  stop)   [[ -n "$arg" ]] || usage
          if [[ "$arg" == proxy ]]; then docker stop "${PREFIX}-proxy" 2>/dev/null || true
          else docker ps -a --filter "name=${PREFIX}-${arg}-" --format '{{.Names}}' | xargs -r docker stop; fi
          exit 0 ;;
  rm)     [[ -n "$arg" ]] || usage
          if [[ "$arg" == proxy ]]; then docker rm -f "${PREFIX}-proxy" 2>/dev/null || true
          else docker ps -a --filter "name=${PREFIX}-${arg}-" --format '{{.Names}}' | xargs -r docker rm -f; fi
          exit 0 ;;
  clean)  docker ps -a --filter "name=${PREFIX}-" --format '{{.Names}}' | xargs -r docker rm -f; echo "已清理全部 ${PREFIX}-* 容器"; exit 0 ;;
  health) # 本机视角巡检全部后端(经各节点 IP)
          rc=0
          for i in "${!P_IPS[@]}"; do
            curl --noproxy '*' -sf --max-time 5 "http://${P_IPS[$i]}:${PREFILL_HTTP_PORT}/health" >/dev/null \
              && echo "P${i} ${P_IPS[$i]}: OK" || { echo "P${i} ${P_IPS[$i]}: 未就绪"; rc=1; }
          done
          for j in "${!D_IPS[@]}"; do
            curl --noproxy '*' -sf --max-time 5 "http://${D_IPS[$j]}:${DECODE_HTTP_PORT}/health" >/dev/null \
              && echo "D${j} ${D_IPS[$j]}: OK" || { echo "D${j} ${D_IPS[$j]}: 未就绪"; rc=1; }
          done
          exit $rc ;;
esac

# ---------- 预检(check / 启动前共用) ----------
preflight() {
  local want=$1
  [[ "$role" == "$want" ]] || { echo "本机($NODE_IP)角色为 ${role:-无},不是 $want;核对 config.env 拓扑" >&2; exit 1; }
  [[ -n "$role" ]] || { echo "本机 IP $NODE_IP 不在 PREFILL_IPS/DECODE_IPS/PROXY_IP 中" >&2; exit 1; }
  ip -4 addr show dev "$NODE_NIC" | grep -Fq "inet ${NODE_IP}/" || { echo "NODE_IP $NODE_IP 不在网卡 $NODE_NIC 上" >&2; exit 1; }
  command -v docker >/dev/null && docker info >/dev/null || { echo "Docker 不可用" >&2; exit 1; }
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "镜像 $IMAGE 不存在,先 docker pull/load" >&2; exit 1; }
  [[ "$role" == proxy ]] && return 0
  # 引擎角色: 模型 + 设备 + 驱动
  [[ -f "$MODEL_PATH/config.json" ]] || { echo "$MODEL_PATH 缺 config.json(挂载/下载问题)" >&2; exit 1; }
  (( NPU_COUNT >= 1 )) || { echo "未发现 /dev/davinci* 设备" >&2; exit 1; }
  local p
  for p in /dev/davinci_manager /dev/hisi_hdc; do
    [[ -e "$p" ]] || echo "WARN: 缺 $p(部分环境无此设备,继续)" >&2
  done
  [[ -d /usr/local/Ascend/driver ]] || { echo "缺 /usr/local/Ascend/driver,驱动未装或路径不同" >&2; exit 1; }
  (( kv_port >= KV_PORT_FLOOR )) || { echo "kv_port $kv_port < 卡数推导下限 $KV_PORT_FLOOR($NPU_COUNT 卡),调大 KV_PORT_BASE" >&2; exit 1; }
  # 量化参数 × 权重交叉校验
  local all_args="$COMMON_EXTRA_ARGS $PREFILL_EXTRA_ARGS $DECODE_EXTRA_ARGS"
  if [[ "$all_args" == *"--quantization"* && ! -f "$MODEL_PATH/quant_model_description.json" ]]; then
    echo "ERROR: 启用了 --quantization 但权重目录无 quant_model_description.json(BF16 权重误带量化参数)" >&2; exit 1
  fi
  if [[ "$all_args" != *"--quantization"* && -f "$MODEL_PATH/quant_model_description.json" ]]; then
    echo "WARN: 量化版权重但未加 --quantization 参数,精度会退化,核对模型文档" >&2
  fi
  echo "[preflight] role=$role inst=$inst chip=$CHIP npu=$NPU_COUNT nic=$NODE_NIC kv_port=$kv_port engine_id=$engine_id OK"
}

case "$action" in
  check) preflight "${arg:-$role}"; exit 0 ;;
  prefill|decode|proxy) [[ -z "$arg" ]] || usage ;;
  test) ;;
  *) usage ;;
esac

WS_DIR=$(pwd)
mkdir -p "$WS_DIR"

# Proxy 与某 Prefill 同机时,显式 proxy 子命令按 proxy 角色处理(NODE_IP 匹配顺序默认判 prefill)
if [[ "$action" == proxy && "$NODE_IP" == "$PROXY_IP" ]]; then
  role=proxy; inst=-1
fi

# ---------- test: Proxy 在跑 + 后端健康 + 经 Proxy 发一条请求 ----------
if [[ "$action" == test ]]; then
  [[ $(docker inspect --format '{{.State.Running}}' "${PREFIX}-proxy" 2>/dev/null) == true ]] || { echo "Proxy 未运行" >&2; exit 1; }
  "$0" health >/dev/null || { echo "存在未就绪后端" >&2; exit 1; }
  curl --noproxy '*' -sf --max-time 10 "http://127.0.0.1:${PROXY_PORT}/v1/models" | grep -q "$SERVED_MODEL_NAME" || { echo "/v1/models 无 $SERVED_MODEL_NAME" >&2; exit 1; }
  curl --noproxy '*' --fail-with-body -sS --max-time 300 "http://127.0.0.1:${PROXY_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${SERVED_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"请只回答:部署成功\"}],\"max_completion_tokens\":64}"
  printf '\n'; exit 0
fi

# ---------- 已存在容器: 启动或提示 ----------
container=$(container_for "$role")
if docker container inspect "$container" >/dev/null 2>&1; then
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]]; then
    echo "$container 已在运行(日志: $0 logs $role)"
  else
    docker start "$container"; echo "已重启 $container(注意: 修改 config.env 须先 rm 再启动)"
  fi
  exit 0
fi
preflight "$role"

# ---------- Proxy: 不占 NPU,镜像自带负载均衡示例 ----------
if [[ "$role" == proxy ]]; then
  p_hosts=$(IFS=,; echo "${P_IPS[*]}"); d_hosts=$(IFS=,; echo "${D_IPS[*]}")
  p_ports=$PREFILL_HTTP_PORT; d_ports=$DECODE_HTTP_PORT
  docker run -d --name "$container" --restart unless-stopped --network host \
    -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= -e all_proxy= -e ALL_PROXY= \
    "$IMAGE" python3 /vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py \
      --host 0.0.0.0 --port "$PROXY_PORT" --workers 1 \
      --prefiller-hosts "$p_hosts" --prefiller-ports "$p_ports" \
      --decoder-hosts "$d_hosts" --decoder-ports "$d_ports"
  echo "Proxy 已启动: http://${NODE_IP}:${PROXY_PORT}/v1 (确保全部后端 /health 已 200 再启动 Proxy)"
  exit 0
fi

# ---------- 引擎角色: 生成容器内启动脚本(含 950 系列 hixlep 兜底) ----------
dp_local=$([[ "$role" == prefill ]] && echo "$PREFILL_DP_LOCAL" || echo "$DECODE_DP_LOCAL")
role_extra=$([[ "$role" == prefill ]] && echo "$PREFILL_EXTRA_ARGS" || echo "$DECODE_EXTRA_ARGS")
inner="$WS_DIR/run_${role}_${inst}.sh"
cat > "$inner" <<EOF
#!/bin/bash
set -e
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY NO_PROXY no_proxy
export HCCL_BUFFSIZE=${HCCL_BUFFSIZE}
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export VLLM_RPC_TIMEOUT=${VLLM_RPC_TIMEOUT:-360000}
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=${VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS:-3000}
export VLLM_ENGINE_READY_TIMEOUT_S=${VLLM_ENGINE_READY_TIMEOUT_S:-1200}
HIXLEP_RES=""
# 950 系列(A5)UB 通信: 宿主机 /etc/hixlep 有文件则直接用;缺失时用离线包生成到 /tmp/hixlep
if [[ "${CHIP}" == 950 ]]; then
  export ASCEND_LOCAL_COMM_RES='{"version":"1.3"}'
  if ls /etc/hixlep/ub_endpoint_npu_*.json >/dev/null 2>&1; then
    echo "[hixlep] 使用宿主机 /etc/hixlep"
  elif [[ -d /workspace/a5_hixlep ]]; then
    echo "[hixlep] /etc/hixlep 缺失,用离线包生成"
    bash /workspace/a5_hixlep/gen_inner_hixlep.sh && HIXLEP_RES="/tmp/hixlep"
  else
    echo "[ERROR] 950 系列 PD 需要 hixlep,宿主机无 /etc/hixlep 且未分发 a5_hixlep 离线包" >&2; exit 1
  fi
fi
KV_CONFIG=\$(python3 - <<'PYKV'
import json, os, sys
kv = {
  "kv_connector": os.environ["KV_CONNECTOR"],
  "kv_role": os.environ["KV_ROLE"],
  "kv_port": int(os.environ["KV_PORT_ACTUAL"]),
  "kv_connector_extra_config": {
    "prefill": {"dp_size": int(os.environ["PREFILL_DP_LOCAL"]), "tp_size": int(os.environ["TP_SIZE"])},
    "decode":  {"dp_size": int(os.environ["DECODE_DP_LOCAL"]), "tp_size": int(os.environ["TP_SIZE"])},
  },
}
if os.environ["KV_CONNECTOR"] == "MooncakeHybridConnector":
    kv["engine_id"] = os.environ["ENGINE_ID"]
else:  # MooncakeConnectorV1
    kv["kv_port"] = os.environ["KV_PORT_ACTUAL"]
    kv["kv_buffer_device"] = "npu"
    if os.environ.get("HIXLEP_RES"):
        kv["kv_connector_extra_config"]["ascend_local_comm_res_path"] = os.environ["HIXLEP_RES"]
print(json.dumps(kv, separators=(',', ':')))
PYKV
)
exec vllm serve "${MODEL_PATH}" \\
  --host 0.0.0.0 --port ${http_port} \\
  --served-model-name "${SERVED_MODEL_NAME}" \\
  --tensor-parallel-size ${TP_SIZE} \\
  --data-parallel-size ${dp_local} --data-parallel-size-local ${dp_local} \\
  --dtype ${DTYPE} --max-model-len ${MAX_MODEL_LEN} \\
  --max-num-seqs ${MAX_NUM_SEQS} --max-num-batched-tokens ${MAX_NUM_BATCHED_TOKENS} \\
  --gpu-memory-utilization ${GPU_MEM_UTIL} --trust-remote-code \\
  --kv-transfer-config "\$KV_CONFIG" \\
  ${COMMON_EXTRA_ARGS} ${role_extra}
EOF
chmod +x "$inner"

# 950 且宿主机无 hixlep 时,生成 a5_hixlep 的容器内兜底脚本(仅 A5 需要;A2/A3 不会走到)
if is_950 && ! ls /etc/hixlep/ub_endpoint_npu_*.json >/dev/null 2>&1 && [[ -d "$WS_DIR/a5_hixlep" ]]; then
cat > "$WS_DIR/a5_hixlep/gen_inner_hixlep.sh" <<'GENEP'
#!/bin/bash
# 容器内 hixlep 生成(950 系列 PD 兜底);细节见 references/mooncake-pd-notes.md 第三节
set -e
PKG=/workspace/a5_hixlep
ROOTINFO=/etc/hccl_rootinfo.json
mkdir -p /tmp/hixlep
# 1) rootinfo 缺失则离线生成(console script 名是 mindcluster-tools,不是 python -m)
if [ ! -s "$ROOTINFO" ]; then
  pip install --no-index --no-deps -q "$PKG/unofficial_ascend_tools-0.0.7rc4-py3-none-any.whl"
  mindcluster-tools rootinfo --product_type server --output "$ROOTINFO"
fi
# 2) local_id 按 rank_list 索引重排为 0..N-1(对齐 route.conf dev_id)
ADJ=/tmp/hccl_rootinfo_adj.json
cp "$ROOTINFO" "$ADJ"
python3 - "$ADJ" <<'PYADJ'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
rl = d.get("rank_list", [])
for i, r in enumerate(rl):
    if isinstance(r.get("local_id"), int): r["local_id"] = i
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
print(f"[hixlep] local_id 重排为 0..{len(rl)-1}")
PYADJ
TOPO=$(python3 -c "import json;print(json.load(open('$ADJ')).get('topo_file_path',''))")
[ -n "$TOPO" ] || { echo "rootinfo 缺 topo_file_path" >&2; exit 1; }
# 3) route.conf 缺失则生成(需 HDK 驱动 /proc 接口)
[ -s /lib/route.conf ] || bash "$PKG/gen_route.sh"
# 4) 生成 endpoint + 修正 NPU ID ↔ Chip Phy-ID 文件名
( cd "$PKG" && python3 generate_ep.py --local --server \
    --rootinfo-path "$ADJ" --route-path /lib/route.conf --topo-path "$TOPO" --output-dir /tmp/hixlep )
command -v npu-smi >/dev/null 2>&1 && HIXLEP_DIR=/tmp/hixlep python3 "$PKG/fix_ub_endpoint.py" -y || true
N=$(ls /tmp/hixlep/ub_endpoint_npu_*.json 2>/dev/null | wc -l)
echo "[hixlep] 生成完成: $N 个 endpoint"
[ "$N" -ge 1 ]
GENEP
chmod +x "$WS_DIR/a5_hixlep/gen_inner_hixlep.sh"
fi

# ---------- docker run 引擎容器 ----------
args=(run -d --name "$container" --restart unless-stopped --network host --shm-size 1g
      -e KV_CONNECTOR="$KV_CONNECTOR" -e KV_ROLE="$kv_role" -e KV_PORT_ACTUAL="$kv_port"
      -e ENGINE_ID="$engine_id" -e TP_SIZE="$TP_SIZE"
      -e PREFILL_DP_LOCAL="$PREFILL_DP_LOCAL" -e DECODE_DP_LOCAL="$DECODE_DP_LOCAL"
      -e VLLM_HOST_IP="$NODE_IP" -e HCCL_IF_IP="$NODE_IP"
      -e GLOO_SOCKET_IFNAME="$NODE_NIC" -e TP_SOCKET_IFNAME="$NODE_NIC" -e HCCL_SOCKET_IFNAME="$NODE_NIC"
      -e CHIP="$CHIP" -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= -e all_proxy= -e ALL_PROXY=)
for d in /dev/davinci[0-9]* /dev/davinci_manager /dev/hisi_hdc /dev/ummu /dev/uburma /dev/infiniband; do
  [[ -e "$d" ]] && args+=(--device "$d")
done
for p in /usr/local/Ascend/driver /etc/ascend_install.info /etc/hccl_rootinfo.json /etc/cloud/topo \
         /etc/hccn.conf /etc/libibverbs.d/hrn5.driver /etc/hixlep /usr/local/dcmi \
         /usr/local/bin/npu-smi /usr/local/sbin/npu-smi /usr/bin/urma_admin; do
  [[ -e "$p" ]] && args+=(-v "$p:$p:ro")
done
# RDMA 驱动库版本匹配(缺失致 HCCL error code 4;存在才挂)
[[ -f /usr/lib64/libhrn5-rdmav34.so ]] && \
  args+=(-v /usr/lib64/libhrn5-rdmav34.so:/usr/lib/aarch64-linux-gnu/libibverbs/libhrn5-rdmav34.so:ro)
[[ -f /usr/lib64/libibv_extend.so.4.2.0 ]] && \
  args+=(-v /usr/lib64/libibv_extend.so.4.2.0:/usr/lib/aarch64-linux-gnu/libibv_extend.so.4:ro)
args+=(-v "$MODEL_PATH:$MODEL_PATH:ro" -v "$WS_DIR:/workspace")
docker "${args[@]}" "$IMAGE" bash "/workspace/run_${role}_${inst}.sh"
echo "已启动 $container(${NODE_IP}:${http_port}, engine_id=$engine_id, kv_port=$kv_port)"
echo "等待就绪: curl --noproxy '*' http://${NODE_IP}:${http_port}/health  (首次 10~20 分钟)"
echo "跟踪日志: $0 logs $role"
