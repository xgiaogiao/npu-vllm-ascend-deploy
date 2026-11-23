#!/bin/bash
# 多源强制拉取: 每段请求在源列表间轮换(hlmirror 匿名直连优先,quay 签名直连兜底)
# 卡速 30KB/s 超 25s 自动断开换源重试;产物 docker load 进本机 → 触发 auto_pipeline
set -Eeuo pipefail
REG=quay.io; REPO=ascend/vllm-ascend; TAG=v0.30.0-a3
IMAGE_REF="quay.io/ascend/vllm-ascend:${TAG}"
DIR=/mnt/sfs_turbo/deploy/img-fast
NPAR=10
SOURCES="quay.hlmirror.com quay.io"
mkdir -p "$DIR/blobs/sha256"; cd "$DIR"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

tk() { cat "$DIR/token.txt" 2>/dev/null; }
token_refresh() {
  curl -sk --max-time 60 --retry 8 --retry-all-errors --retry-delay 2 \
    "https://${REG}/v2/auth?service=quay.io&scope=repository:${REPO}:pull" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])' > "$DIR/token.txt"
}
token_refresh
( while true; do sleep 1500; token_refresh; done ) &
REFRESHER=$!
echo "[fp2] $(date +%H:%M:%S) token OK"

# manifest: 源顺序尝试
M=""
for host in $SOURCES; do
  if [[ "$host" == "$REG" ]]; then
    M=$(curl -sk --max-time 30 --retry 3 -H "Authorization: Bearer $(tk)" -H "Accept: ${ACCEPT}" "https://${host}/v2/${REPO}/manifests/${TAG}" || true)
  else
    M=$(curl -sk --max-time 30 --retry 3 -H "Accept: ${ACCEPT}" "https://${host}/v2/${REPO}/manifests/${TAG}" || true)
  fi
  echo "$M" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null && { echo "[fp2] manifest 来自 $host"; break; }
  M=""
done
[[ -n "$M" ]] || { echo "[fp2] manifest 全源失败"; exit 1; }
ARM=$(echo "$M" | python3 -c 'import json,sys
d=json.load(sys.stdin)
if "manifests" in d:
    for m in d["manifests"]:
        if m.get("platform",{}).get("architecture") in ("arm64","aarch64"): print(m["digest"]);break
' || true)
if [[ -n "$ARM" ]]; then
  M=$(curl -sk --max-time 30 --retry 3 -H "Accept: ${ACCEPT}" "https://quay.hlmirror.com/v2/${REPO}/manifests/${ARM}" \
     || curl -sk --max-time 30 --retry 3 -H "Authorization: Bearer $(tk)" -H "Accept: ${ACCEPT}" "https://${REG}/v2/${REPO}/manifests/${ARM}")
fi
echo "$M" | python3 -c '
import json,sys
m=json.load(sys.stdin)
json.dump({"config":m["config"]["digest"],"config_size":m["config"]["size"],
           "layers":[l["digest"] for l in m["layers"]],
           "sizes":{l["digest"]:l["size"] for l in m["layers"]}},open("meta.json","w"))
print("[fp2] meta OK, layers:",len(m["layers"]))'

url_for() { # $1=host $2=digest
  if [[ "$1" == "$REG" ]]; then
    local u; u=$(curl -sk -o /dev/null -w "%{redirect_url}" --max-time 30 --retry 3 -H "Authorization: Bearer $(tk)" "https://${REG}/v2/${REPO}/blobs/$2" 2>/dev/null) || u=""
    echo "${u:-https://${REG}/v2/${REPO}/blobs/$2}"
  else
    echo "https://$1/v2/${REPO}/blobs/$2"
  fi
}
export -f url_for tk
export REG REPO DIR

dl_range() { # $1=digest $2=start $3=len $4=out
  local d=$1 s=$2 l=$3 f=$4 host u t
  for t in $(seq 1 100); do
    for host in $SOURCES; do
      u=$(url_for "$host" "$d")
      curl -sk -f -r "${s}-$((s+l-1))" -o "$f" \
        --speed-limit 30000 --speed-time 25 --connect-timeout 12 --max-time 480 "$u" 2>/dev/null
      [[ -f "$f" && "$(stat -c%s "$f")" == "$l" ]] && return 0
      rm -f "$f"
    done
    sleep 2
  done
  return 1
}
export -f dl_range
export SOURCES

python3 - <<'PY' > dl_tasks.tsv
import json
m = json.load(open("meta.json"))
for kind, d, l in [("cfg", m["config"], m["config_size"])] + [("layer", d, m["sizes"][d]) for d in m["layers"]]:
    print(f"{kind}\t{d}\t{l}")
PY
TOTAL=$(awk -F'\t' '{n+=$3}END{print n}' dl_tasks.tsv)
echo "[fp2] 总量 $((TOTAL/1048576))MB"
I=0; N=$(wc -l < dl_tasks.tsv)
while IFS=$'\t' read -r kind dig len; do
  I=$((I+1)); hex=${dig#sha256:}; out="blobs/sha256/$hex"
  if [[ -f "$out" && "$(stat -c%s "$out")" == "$len" ]]; then echo "[fp2] ($I/$N) 已存在"; continue; fi
  t0=$(date +%s)
  if (( len < 64*1048576 )); then
    dl_range "$dig" 0 "$len" "$out" || { echo "[fp2] ($I/$N) 失败"; exit 1; }
  else
    seg=$(( (len + NPAR - 1) / NPAR )); seg=$(( (seg/8388608+1)*8388608 ))
    rm -f "$out".part*
    for p in $(seq 0 $((NPAR-1))); do
      s=$((p*seg)); (( s >= len )) && break
      l=$(( len-s < seg ? len-s : seg ))
      printf '%s\n' "$dig $s $l $out.part$p"
    done | xargs -P "$NPAR" -n 4 bash -c 'dl_range "$@"' _
    > "$out"
    for p in $(seq 0 $((NPAR-1))); do cat "$out.part$p" >> "$out" 2>/dev/null && rm -f "$out.part$p"; done
    [[ "$(stat -c%s "$out")" == "$len" ]] || { echo "[fp2] ($I/$N) 合并校验失败"; exit 1; }
  fi
  dt=$(( $(date +%s)-t0 ))
  echo "[fp2] ($I/$N) $kind $((len/1048576))MB ${dt}s $((len/1048576/(dt+1)))MB/s $(date +%H:%M:%S)"
done < dl_tasks.tsv

python3 - <<'PY'
import json, shutil
m = json.load(open("meta.json"))
cfg_hex = m["config"].split(":")[1]
shutil.copy(f"blobs/sha256/{cfg_hex}", f"{cfg_hex}.json")
layers = [f"blobs/sha256/{d.split(':')[1]}" for d in m["layers"]]
json.dump([{"Config": f"{cfg_hex}.json", "RepoTags": ["quay.io/ascend/vllm-ascend:v0.30.0-a3"], "Layers": layers}], open("manifest.json","w"))
print("[fp2] manifest.json OK")
PY
CFG=$(python3 -c 'import json;print(json.load(open("meta.json"))["config"].split(":")[1])')
echo "[fp2] 打包 tar ..."
tar -cf image.tar manifest.json "${CFG}.json" $(python3 -c 'import json;m=json.load(open("meta.json"));print(" ".join("blobs/sha256/"+d.split(":")[1] for d in m["layers"]))')
echo "[fp2] docker load ..."
docker load -i image.tar && { echo "FAST2_DONE"; echo OK > /tmp/fastpull_status; }
kill $REFRESHER 2>/dev/null || true
