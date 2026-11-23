#!/usr/bin/env bash
# 单机部署管理脚本(昇腾 NPU 裸机 Docker,1 节点 1 容器,TP=卡数内切分)
# 用法: ./single.sh check|start|health|test|status|logs|stop|rm
# 配置: 同目录 config.env 的 IMAGE/MODEL_PATH/SERVED_MODEL_NAME/TP_SIZE/DTYPE/MAX_MODEL_LEN/
#       GPU_MEM_UTIL/MAX_NUM_SEQS/MAX_NUM_BATCHED_TOKENS/HCCL_BUFFSIZE/COMMON_EXTRA_ARGS/PREFIX 生效,
#       PD 相关变量忽略。取值以 vllm-ascend 模型适配文档为准。
set -Eeuo pipefail
cd "$(dirname "$0")"
usage() { echo "Usage: $0 check|start|health|test|status|logs|stop|rm" >&2; exit 2; }
action=${1:-}; [[ -n "$action" ]] || usage
[[ -f config.env ]] || { echo "缺少 config.env" >&2; exit 1; }
# shellcheck disable=SC1091
source ./config.env
: "${IMAGE:?}" "${MODEL_PATH:?}" "${SERVED_MODEL_NAME:?}"
: "${TP_SIZE:=8}" "${DTYPE:=bfloat16}" "${MAX_MODEL_LEN:=131072}" "${GPU_MEM_UTIL:=0.85}"
: "${MAX_NUM_SEQS:=8}" "${MAX_NUM_BATCHED_TOKENS:=8192}" "${HCCL_BUFFSIZE:=512}" "${PREFIX:=vllm-single}"
: "${HTTP_PORT:=8000}"
COMMON_EXTRA_ARGS=${COMMON_EXTRA_ARGS:-}
CONTAINER="${PREFIX}-single"

NPU_COUNT=$( { ls /dev/davinci[0-9]* 2>/dev/null || true; } | wc -l)
NODE_IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
NODE_NIC=$(ip -4 -o addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')

case "$action" in
  status) docker ps -a --filter "name=${CONTAINER}"; exit 0 ;;
  logs)   docker logs -f "$CONTAINER"; exit 0 ;;
  stop)   docker stop "$CONTAINER" 2>/dev/null || true; exit 0 ;;
  rm)     docker rm -f "$CONTAINER" 2>/dev/null || true; exit 0 ;;
  health) curl --noproxy '*' -sf --max-time 5 "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null && echo OK || { echo 未就绪; exit 1; } ;;
esac

# 预检
preflight() {
  command -v docker >/dev/null && docker info >/dev/null || { echo "Docker 不可用" >&2; exit 1; }
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "镜像 $IMAGE 不存在" >&2; exit 1; }
  [[ -f "$MODEL_PATH/config.json" ]] || { echo "$MODEL_PATH 缺 config.json" >&2; exit 1; }
  (( NPU_COUNT >= TP_SIZE )) || { echo "NPU 卡数 $NPU_COUNT < TP_SIZE $TP_SIZE" >&2; exit 1; }
  if [[ "$COMMON_EXTRA_ARGS" == *"--quantization"* && ! -f "$MODEL_PATH/quant_model_description.json" ]]; then
    echo "ERROR: --quantization 但权重无 quant_model_description.json" >&2; exit 1
  fi
  echo "[preflight] npu=$NPU_COUNT tp=$TP_SIZE ip=$NODE_IP nic=$NODE_NIC OK"
}

case "$action" in
  check) preflight; exit 0 ;;
  test)
    curl --noproxy '*' -sf --max-time 10 "http://127.0.0.1:${HTTP_PORT}/v1/models" | grep -q "$SERVED_MODEL_NAME" || { echo "/v1/models 异常" >&2; exit 1; }
    curl --noproxy '*' --fail-with-body -sS --max-time 300 "http://127.0.0.1:${HTTP_PORT}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${SERVED_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"请只回答:部署成功\"}],\"max_completion_tokens\":64}"
    printf '\n'; exit 0 ;;
  start) ;;
  *) usage ;;
esac

if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  if [[ $(docker inspect --format '{{.State.Running}}' "$CONTAINER") == true ]]; then
    echo "$CONTAINER 已在运行(改配置须 rm 重建)"; exit 0
  fi
  docker start "$CONTAINER"; echo "已重启 $CONTAINER"; exit 0
fi
preflight

args=(run -d --name "$CONTAINER" --restart unless-stopped --network host --shm-size 1g
      -e VLLM_HOST_IP="$NODE_IP" -e HCCL_IF_IP="$NODE_IP" -e HCCL_BUFFSIZE="$HCCL_BUFFSIZE"
      -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
      -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= -e all_proxy= -e ALL_PROXY=)
[[ -n "$NODE_NIC" ]] && args+=(-e GLOO_SOCKET_IFNAME="$NODE_NIC" -e TP_SOCKET_IFNAME="$NODE_NIC" -e HCCL_SOCKET_IFNAME="$NODE_NIC")
for d in /dev/davinci[0-9]* /dev/davinci_manager /dev/hisi_hdc /dev/ummu /dev/uburma /dev/infiniband; do
  [[ -e "$d" ]] && args+=(--device "$d")
done
for p in /usr/local/Ascend/driver /etc/ascend_install.info /etc/hccl_rootinfo.json /etc/cloud/topo \
         /etc/hccn.conf /usr/local/dcmi /usr/local/bin/npu-smi /usr/local/sbin/npu-smi; do
  [[ -e "$p" ]] && args+=(-v "$p:$p:ro")
done
args+=(-v "$MODEL_PATH:$MODEL_PATH:ro")
docker "${args[@]}" "$IMAGE" \
  vllm serve "$MODEL_PATH" \
    --host 0.0.0.0 --port "$HTTP_PORT" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --tensor-parallel-size "$TP_SIZE" \
    --dtype "$DTYPE" --max-model-len "$MAX_MODEL_LEN" \
    --max-num-seqs "$MAX_NUM_SEQS" --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
    --gpu-memory-utilization "$GPU_MEM_UTIL" --trust-remote-code \
    $COMMON_EXTRA_ARGS
echo "已启动 $CONTAINER: http://${NODE_IP}:${HTTP_PORT}/v1 (首次就绪 10~20 分钟,以 /health 200 为准)"
