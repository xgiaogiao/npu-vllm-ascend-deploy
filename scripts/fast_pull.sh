#!/bin/bash
# .98 上强制拉取 quay 镜像: 并发分段 + 失败重试 + 卡速自动断开重连 + 签名刷新
# 与 docker pull 并行竞速,产物 /mnt/sfs_turbo/deploy/img-fast/image.tar
set -Eeuo pipefail
REG=quay.io; REPO=ascend/vllm-ascend; TAG=v0.30.0-a3
IMAGE_REF="quay.io/ascend/vllm-ascend:${TAG}"
DIR=/mnt/sfs_turbo/deploy/img-fast
NPAR=8
mkdir -p "$DIR/blobs/sha256"; cd "$DIR"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

token_refresh() {
  curl -sk --max-time 60 --retry 8 --retry-all-errors --retry-delay 2 \
    "https://${REG}/v2/auth?service=quay.io&scope=repository:${REPO}:pull" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])' > "$DIR/token.txt"
}
signed() { # $1=digest → 签名直链(读 token.txt,后台定时刷新)
  local tk u
  tk=$(cat "$DIR/token.txt" 2>/dev/null)
  u=$(curl -sk -o /dev/null -w "%{redirect_url}" --max-time 30 --retry 5 --retry-all-errors -H "Authorization: Bearer ${tk}" "https://${REG}/v2/${REPO}/blobs/$1") || u=""
  echo "${u:-https://${REG}/v2/${REPO}/blobs/$1}"
}
export -f signed
export REG REPO DIR

token_refresh
# 后台每 25 分钟刷新 token(签名 1 小时有效)
( while true; do sleep 1500; token_refresh; done ) &
REFRESHER=$!
echo "[fast_pull] $(date +%H:%M:%S) token OK(后台定时刷新 pid=$REFRESHER)"
TK=$(cat "$DIR/token.txt")
M=$(curl -sk --retry 8 --retry-all-errors -H "Authorization: Bearer ${TK}" -H "Accept: ${ACCEPT}" "https://${REG}/v2/${REPO}/manifests/${TAG}")
ARM=$(echo "$M" | python3 -c 'import json,sys
d=json.load(sys.stdin)
if "manifests" in d:
    for m in d["manifests"]:
        if m.get("platform",{}).get("architecture") in ("arm64","aarch64"): print(m["digest"]);break
' || true)
[[ -n "$ARM" ]] && M=$(curl -sk --retry 8 --retry-all-errors -H "Authorization: Bearer ${TK}" -H "Accept: ${ACCEPT}" "https://${REG}/v2/${REPO}/manifests/${ARM}")
echo "$M" | python3 -c '
import json,sys
m=json.load(sys.stdin)
json.dump({"config":m["config"]["digest"],"config_size":m["config"]["size"],
           "layers":[l["digest"] for l in m["layers"]],
           "sizes":{l["digest"]:l["size"] for l in m["layers"]}},open("meta.json","w"))
print("[fast_pull] meta.json OK, layers:",len(m["layers"]))'

dl_range() { # $1=digest $2=start $3=len $4=outfile  (stdin 不用;环境: REG REPO TOKEN 经 env 传入)
  local d=$1 s=$2 l=$3 f=$4 u t
  for t in $(seq 1 80); do
    u=$(signed "$d")
    curl -sk -f -r "${s}-$((s+l-1))" -o "$f" \
      --speed-limit 30000 --speed-time 25 --connect-timeout 15 --max-time 600 "$u" 2>/dev/null
    [[ -f "$f" && "$(stat -c%s "$f")" == "$l" ]] && return 0
    sleep 2
  done
  return 1
}
export -f dl_range

python3 - <<'PY' > dl_tasks.tsv
import json
m = json.load(open("meta.json"))
rows = [("cfg", m["config"], 0, m["config_size"])]
for d in m["layers"]:
    rows.append(("layer", d, 0, m["sizes"][d]))
for kind, d, s, l in rows:
    print(f"{kind}\t{d}\t{s}\t{l}")
PY

TOTAL=$(awk -F'\t' '{n+=$4}END{print n}' dl_tasks.tsv)
echo "[fast_pull] 总量 $((TOTAL/1048576))MB, 大层拆 ${NPAR} 段并发"
I=0; N=$(wc -l < dl_tasks.tsv)
while IFS=$'\t' read -r kind dig start len; do
  I=$((I+1)); hex=${dig#sha256:}; out="blobs/sha256/$hex"
  if [[ -f "$out" && "$(stat -c%s "$out")" == "$len" ]]; then echo "[fast_pull] ($I/$N) $hex 已存在"; continue; fi
  t0=$(date +%s)
  if (( len < 64*1048576 )); then
    dl_range "$dig" 0 "$len" "$out" || { echo "[fast_pull] ($I/$N) $hex 失败"; exit 1; }
  else
    seg=$(( (len + NPAR - 1) / NPAR )); seg=$(( (seg/8388608+1)*8388608 ))
    rm -f "$out".part*
    for p in $(seq 0 $((NPAR-1))); do
      s=$((p*seg)); (( s >= len )) && break
      l=$(( len-s < seg ? len-s : seg ))
      printf '%s\n' "$dig $s $l $out.part$p"
    done | xargs -P "$NPAR" -n 4 bash -c 'dl_range "$@"' _
    # 校验+合并
    > "$out"
    for p in $(seq 0 $((NPAR-1))); do
      pf="$out.part$p"; [[ -f "$pf" ]] && cat "$pf" >> "$out" && rm -f "$pf"
    done
    [[ "$(stat -c%s "$out")" == "$len" ]] || { echo "[fast_pull] ($I/$N) $hex 合并校验失败"; exit 1; }
  fi
  dt=$(( $(date +%s)-t0 ))
  echo "[fast_pull] ($I/$N) $kind $hex $((len/1048576))MB ${dt}s $((len/1048576/(dt+1)))MB/s $(date +%H:%M:%S)"
done < dl_tasks.tsv

# docker load 包
python3 - <<'PY'
import json, shutil
m = json.load(open("meta.json"))
cfg_hex = m["config"].split(":")[1]
shutil.copy(f"blobs/sha256/{cfg_hex}", f"{cfg_hex}.json")
layers = [f"blobs/sha256/{d.split(':')[1]}" for d in m["layers"]]
json.dump([{"Config": f"{cfg_hex}.json", "RepoTags": ["quay.io/ascend/vllm-ascend:v0.30.0-a3"], "Layers": layers}], open("manifest.json","w"))
print("[fast_pull] manifest.json OK")
PY
CFG=$(python3 -c 'import json;print(json.load(open("meta.json"))["config"].split(":")[1])')
echo "[fast_pull] 打包 image.tar ..."
tar -cf image.tar manifest.json "${CFG}.json" $(python3 -c 'import json;m=json.load(open("meta.json"));print(" ".join("blobs/sha256/"+d.split(":")[1] for d in m["layers"]))')
echo "[fast_pull] tar 完成 $(( $(stat -c%s image.tar)/1048576/1024 ))GB, 开始 docker load ..."
docker load -i image.tar && echo "FAST_PULL_DONE" && echo LOAD_OK > /tmp/fastpull_status
