#!/usr/bin/env bash
# 多机部署管理脚本(昇腾 NPU 裸机 Docker + Ray,一个 vLLM 引擎横跨 k 节点,TP=k×卡数)
# 用法: ./mn.sh head|worker|serve|check|health|test|status|logs|stop|rm
#   head  : head 节点启动 Ray head 容器
#   worker: worker 节点启动 Ray worker 容器(连 HEAD_IP:RAY_PORT)
#   serve : head 节点容器内启动 vllm serve(跨节点 TP)
# 配置: config.env 的 IMAGE/MODEL_PATH/SERVED_MODEL_NAME/TP_SIZE(=k×每节点卡数)/DTYPE/
#       MAX_MODEL_LEN/GPU_MEM_UTIL/HCCL_BUFFSIZE/COMMON_EXTRA_ARGS/PREFIX + HEAD_IP/WORKER_IPS/RAY_PORT 生效。
# 注意: Ray 集群细节(端口//dashboard/对象存储)以 vllm-ascend 多机文档为准;节点间 RAY_PORT 及 HCCL 数据面须放通。
set -Eeuo pipefail
cd "$(dirname "$0")"
usage() { echo "Usage: $0 head|worker|serve|check|health|test|status|logs|stop|rm" >&2; exit 2; }
action=${1:-}; [[ -n "$action" ]] || usage
[[ -f config.env ]] || { echo "缺少 config.env" >&2; exit 1; }
# shellcheck disable=SC1091
source ./config.env
: "${IMAGE:?}" "${MODEL_PATH:?}" "${SERVED_MODEL_NAME:?}" "${HEAD_IP:?}" "${RAY_PORT:=6379}"
: "${TP_SIZE:=16}" "${DTYPE:=bfloat16}" "${MAX_MODEL_LEN:=131072}" "${GPU_MEM_UTIL:=0.9}"
: "${HTTP_PORT:=8000}" "${HCCL_BUFFSIZE:=512}" "${PREFIX:=vllm-mn}"
COMMON_EXTRA_ARGS=${COMMON_EXTRA_ARGS:-}
WORKER_IPS=${WORKER_IPS:-}
read -r -a W_IPS <<< "$WORKER_IPS"

NODE_IP=$( { for cand in "$HEAD_IP" ${W_IPS[@]+"${W_IPS[@]}"}; do
  ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fx "$cand" && break
done; } | head -1 || true)
[[ -n "$NODE_IP" ]] || { echo "本机 IP 不在 HEAD_IP/WORKER_IPS 中(或显式填 NODE_IP)" >&2; exit 1; }
NODE_NIC=$(ip -4 -o addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')
NPU_COUNT=$( { ls /dev/davinci[0-9]* 2>/dev/null || true; } | wc -l)
IS_HEAD=0; [[ "$NODE_IP" == "$HEAD_IP" ]] && IS_HEAD=1
RAY_CNAME=$([[ $IS_HEAD == 1 ]] && echo "${PREFIX}-ray-head" || echo "${PREFIX}-ray-worker")

common_docker_args() {
  local args=(run -d --restart unless-stopped --network host --shm-size 1g
        -e VLLM_HOST_IP="$NODE_IP" -e HCCL_IF_IP="$NODE_IP" -e HCCL_BUFFSIZE="$HCCL_BUFFSIZE"
        -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
        -e GLOO_SOCKET_IFNAME="$NODE_NIC" -e TP_SOCKET_IFNAME="$NODE_NIC" -e HCCL_SOCKET_IFNAME="$NODE_NIC"
        -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= -e all_proxy= -e ALL_PROXY=)
  local d p
  for d in /dev/davinci[0-9]* /dev/davinci_manager /dev/hisi_hdc /dev/ummu /dev/uburma /dev/infiniband; do
    [[ -e "$d" ]] && args+=(--device "$d")
  done
  for p in /usr/local/Ascend/driver /etc/ascend_install.info /etc/hccl_rootinfo.json /etc/cloud/topo \
           /etc/hccn.conf /etc/libibverbs.d/hrn5.driver /etc/hixlep /usr/local/dcmi \
           /usr/local/bin/npu-smi /usr/local/sbin/npu-smi /usr/bin/urma_admin; do
    [[ -e "$p" ]] && args+=(-v "$p:$p:ro")
  done
  [[ -f /usr/lib64/libhrn5-rdmav34.so ]] && \
    args+=(-v /usr/lib64/libhrn5-rdmav34.so:/usr/lib/aarch64-linux-gnu/libibverbs/libhrn5-rdmav34.so:ro)
  [[ -f /usr/lib64/libibv_extend.so.4.2.0 ]] && \
    args+=(-v /usr/lib64/libibv_extend.so.4.2.0:/usr/lib/aarch64-linux-gnu/libibv_extend.so.4:ro)
  args+=(-v "$MODEL_PATH:$MODEL_PATH:ro" -v "$(pwd):/workspace")
  echo "${args[@]}"
}

case "$action" in
  status) docker ps -a --filter "name=${PREFIX}-"; exit 0 ;;
  logs)   docker logs -f "$RAY_CNAME"; exit 0 ;;
  stop)   docker stop "$RAY_CNAME" 2>/dev/null || true; exit 0 ;;
  rm)     docker rm -f "$RAY_CNAME" 2>/dev/null || true; exit 0 ;;
  health) curl --noproxy '*' -sf --max-time 5 "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null && echo OK || { echo 未就绪; exit 1; } ;;
esac

command -v docker >/dev/null && docker info >/dev/null || { echo "Docker 不可用" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "镜像 $IMAGE 不存在" >&2; exit 1; }
[[ -f "$MODEL_PATH/config.json" ]] || { echo "$MODEL_PATH 缺 config.json" >&2; exit 1; }
(( NPU_COUNT >= 1 )) || { echo "无 /dev/davinci* 设备" >&2; exit 1; }

case "$action" in
  check)
    echo "[preflight] node=$NODE_IP role=$( ((IS_HEAD)) && echo head || echo worker ) npu=$NPU_COUNT nic=$NODE_NIC tp_total=$TP_SIZE workers=${#W_IPS[@]} OK"
    (( IS_HEAD == 1 || ${#W_IPS[@]} >= 0 )); exit 0 ;;
  head|worker)
    if docker container inspect "$RAY_CNAME" >/dev/null 2>&1; then
      [[ $(docker inspect --format '{{.State.Running}}' "$RAY_CNAME") == true ]] && { echo "$RAY_CNAME 已在运行"; exit 0; }
      docker start "$RAY_CNAME"; echo "已重启 $RAY_CNAME"; exit 0
    fi
    if [[ $IS_HEAD == 1 && "$action" == head ]]; then
      # shellcheck disable=SC2046
      docker $(common_docker_args) --name "$RAY_CNAME" "$IMAGE" \
        bash -c "ray start --head --port ${RAY_PORT} --dashboard-host 0.0.0.0 --block"
    elif [[ $IS_HEAD == 0 && "$action" == worker ]]; then
      # shellcheck disable=SC2046
      docker $(common_docker_args) --name "$RAY_CNAME" "$IMAGE" \
        bash -c "ray start --address ${HEAD_IP}:${RAY_PORT} --block"
    else
      echo "本机角色(role=head=$IS_HEAD)与子命令 $action 不符" >&2; exit 1
    fi
    echo "$RAY_CNAME 已启动"; exit 0 ;;
  serve)
    (( IS_HEAD == 1 )) || { echo "serve 只在 head 节点执行" >&2; exit 1; }
    docker exec "${PREFIX}-ray-head" bash -lc \
      "pgrep -f 'vllm serve' >/dev/null && { echo serve 已在运行; exit 0; };
       nohup vllm serve '${MODEL_PATH}' \
         --host 0.0.0.0 --port ${HTTP_PORT} \
         --served-model-name '${SERVED_MODEL_NAME}' \
         --tensor-parallel-size ${TP_SIZE} \
         --dtype ${DTYPE} --max-model-len ${MAX_MODEL_LEN} \
         --gpu-memory-utilization ${GPU_MEM_UTIL} --trust-remote-code \
         ${COMMON_EXTRA_ARGS} > /workspace/serve.log 2>&1 &"
    echo "serve 已在 head 容器内启动,日志: docker exec ${PREFIX}-ray-head tail -f /workspace/serve.log"
    echo "就绪判定: curl --noproxy '*' http://${HEAD_IP}:${HTTP_PORT}/health (首次 10~20 分钟)"
    exit 0 ;;
  test)
    curl --noproxy '*' -sf --max-time 10 "http://127.0.0.1:${HTTP_PORT}/v1/models" | grep -q "$SERVED_MODEL_NAME" || { echo "/v1/models 异常" >&2; exit 1; }
    curl --noproxy '*' --fail-with-body -sS --max-time 300 "http://127.0.0.1:${HTTP_PORT}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${SERVED_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"请只回答:部署成功\"}],\"max_completion_tokens\":64}"
    printf '\n'; exit 0 ;;
  *) usage ;;
esac
