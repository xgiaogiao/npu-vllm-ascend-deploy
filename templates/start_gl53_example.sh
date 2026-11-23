#!/usr/bin/env bash
# GLM-5.3 3P1D 启动入口(宿主机执行): ./start.sh <role>  role = prefill|decode|proxy
# 本机角色由 NODE_IP 在 config.env 拓扑中的位置自动判定;容器挂载按官方 A3 文档第 4 节。
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./config.env
: "${IMAGE:?}" "${MODEL_PATH:?}" "${WS_DIR:?}" "${PREFILL_IPS:?}" "${DECODE_IPS:?}" "${PROXY_IP:?}"
ROLE=${1:?用法: ./start.sh prefill|decode|proxy}

read -r -a P_IPS <<< "$PREFILL_IPS"; read -r -a D_IPS <<< "$DECODE_IPS"
NODE_IP=$( { for c in "${P_IPS[@]}" "${D_IPS[@]}" "$PROXY_IP"; do
  ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fx "$c" && break
done; } | head -1 || true)
[[ -n "$NODE_IP" ]] || { echo "本机 IP 不在拓扑中,检查 config.env"; exit 1; }
NIC_NAME=$(ip -4 -o addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')

case "$ROLE" in
  prefill)
    inst=-1; for i in "${!P_IPS[@]}"; do [[ "${P_IPS[$i]}" == "$NODE_IP" ]] && inst=$i; done
    [[ $inst -ge 0 ]] || { echo "本机 $NODE_IP 不是 Prefill 节点"; exit 1; }
    CNAME="${PREFIX}-prefill-${inst}" ;;
  decode)
    inst=-1; for j in "${!D_IPS[@]}"; do [[ "${D_IPS[$j]}" == "$NODE_IP" ]] && inst=$j; done
    [[ $inst -ge 0 ]] || { echo "本机 $NODE_IP 不是 Decode 节点"; exit 1; }
    CNAME="${PREFIX}-decode-${inst}" ;;
  proxy)
    [[ "$NODE_IP" == "$PROXY_IP" ]] || { echo "本机 $NODE_IP 不是 Proxy 节点($PROXY_IP)"; exit 1; }
    inst=0; CNAME="${PREFIX}-proxy" ;;
  *) echo "未知 role: $ROLE"; exit 2 ;;
esac

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "镜像 $IMAGE 不存在,先拉取"; exit 1; }
[[ -f "$MODEL_PATH/config.json" ]] || { echo "$MODEL_PATH 缺 config.json"; exit 1; }

if docker container inspect "$CNAME" >/dev/null 2>&1; then
  if [[ $(docker inspect --format '{{.State.Running}}' "$CNAME") == true ]]; then
    echo "$CNAME 已在运行; 日志: docker logs -f $CNAME"; exit 0
  fi
  docker start "$CNAME"; echo "已重启 $CNAME(改配置须先 docker rm -f $CNAME)"; exit 0
fi

args=(run -d --name "$CNAME" --restart unless-stopped --net=host --shm-size 1g
      -e ROLE="$ROLE" -e INSTANCE="$inst" -e NODE_IP="$NODE_IP" -e NIC_NAME="$NIC_NAME"
      -w /tmp/run)
for d in /dev/davinci[0-9]* /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc; do
  [[ -e "$d" ]] && args+=(--device "$d")
done
for p in /usr/local/dcmi \
         /usr/local/Ascend/driver/tools/hccn_tool \
         /usr/local/bin/npu-smi /usr/local/sbin/npu-smi \
         /usr/local/Ascend/driver/lib64 /usr/local/Ascend/driver/version.info \
         /etc/ascend_install.info /etc/hccn.conf /root/.cache; do
  [[ -e "$p" ]] || continue
  ro=""; [[ "$p" == /etc/hccn.conf ]] && ro=":ro"
  args+=(-v "$p:$p$ro")
done
[[ -e /usr/local/Ascend/driver ]] && args+=(-v /usr/local/Ascend/driver:/usr/local/Ascend/driver)
args+=(-v /mnt/sfs_turbo:/mnt/sfs_turbo:ro -v "$WS_DIR/logs:/tmp/hostlogs")
docker "${args[@]}" "$IMAGE" bash "$WS_DIR/inner.sh"
echo "已启动 $CNAME (role=$ROLE inst=$inst ip=$NODE_IP nic=$NIC_NAME)"
HPORT=$PREFILL_HTTP_PORT; [[ "$ROLE" == decode ]] && HPORT=$DECODE_HTTP_PORT_BASE
echo "就绪判断: curl --noproxy '*' http://${NODE_IP}:${HPORT}/health"
echo "日志: docker logs -f $CNAME"
