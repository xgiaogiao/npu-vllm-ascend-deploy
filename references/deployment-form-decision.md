# 部署形式决策指南(single / multi_node / pd)

## 一、三形式对比

| 维度 | single 单机 | multi_node 多机 | pd PD 分离 |
|------|-------------|-----------------|------------|
| 拓扑 | 1 节点 1 容器,TP=N 卡 | k 节点 Ray 集群,**一个引擎横跨节点**(TP=k×卡数) | x Prefill 引擎 + y Decode 引擎 + 1 Proxy,**每节点 1 独立引擎 1 容器** |
| 模板 | `templates/single.sh` | `templates/multi_node.sh` | `templates/pd.sh` |
| 适用 | 权重单节点放得下,吞吐要求低 | 权重单节点放不下(TP 需跨节点),或文档仅给多机示例 | 高吞吐/低延迟场景;文档明确支持 PD(尤其 Mooncake);xPyD 任意配比(1P1D/2P1D/**3P1D**/4P4D) |
| 依赖 | 基础 | 节点间 Ray 互通(6379/8265) | 节点间 KV 通信(Mooncake,A5 走 UB 需 hixlep) |
| 复杂度 | 低 | 中(需先起 Ray 再 serve) | 中高(角色顺序 + KV 配置) |
| 节点故障影响 | 整体不可用 | 整体不可用(单引擎) | 仅该引擎退出服务,Proxy 可摘除(实例级容错) |

## 二、决策线索(按优先级)

1. **模型适配文档说啥就是啥**: 文档部署章节只给单机示例 → single;给 `--tensor-parallel-size` 超过单节点卡数或明确多机/Ray 示例 → multi_node;有 PD/Mooncake/pd_disaggregation 章节 → pd 可选。**文档没写的形式不要强行套**。
2. **权重与显存**: 单节点(卡数×单卡显存×util)放不下权重 → multi_node 或 pd(量化版权重可改变结论,回步骤 2 重算)。
3. **吞吐/延迟要求**: 用户要高并发 Prefill 吞吐 + 低 Decode 延迟 → pd(xPyD 配比按业务,prefill 密集型选 x>y 如 3P1D,均衡选 2P2D)。
4. **节点数**: 用户节点数 < 形式最小需求 → 降级形式或减配比,与用户确认。pd 最小 2 节点(1P1D)。

## 三、pd 的 xPyD 拓扑细则

- **每节点 1 个独立 vLLM 引擎**(一个 `vllm serve` 容器,host 网络): Prefill-i、Decode-j 各自完整加载一份权重,并行参数(TP / DP-local / EP / PP)按模型文档的 prefill/decode 示例**分别**填(config.env 的 `PREFILL_*` / `DECODE_*` 变量)。
- **Proxy 不占 NPU**: 跑镜像自带 `load_balance_proxy_server_example.py`,与第一个 Prefill 节点同机(host 网络),接收全部客户端请求,按 prefill→decode 两段路由,Prefill 多实例间负载均衡。
- **engine_id / kv_port 全局规划**: Prefill-i → engine_id=i、kv_port=36000+i×10;Decode-j → engine_id=x+j、kv_port=36000+(x+j)×10(x=Prefill 数)。kv_port 必须 ≥28000(避开 Mooncake AscendDirectTransport 随机端口 [20000, 20000+卡数×1000))。
- **已知实战配比参考**(同环境历史部署):
  - Qwen3.8-27B 1P1D: 两侧各 TP=8 DP=1,MooncakeHybridConnector,kv 36000/36100
  - DeepSeek-V4.1-Flash 1P1D: 两侧各 TP=1 DP=8(节点内 8 DP rank)+ `--enable-expert-parallel` + FP8 量化,kv 36010/36020
  - GLM-5.3(ModelArts 侧记录)PD 2P1D prefill TP1/PCP8/PP2/EP8——**跨节点 PP 引擎形态属 multi_node 变体**,裸机 3P1D 优先采用"每节点独立引擎"模式,若模型文档另有指定以文档为准
- **请求链路验证**: 必须**经 Proxy** 发请求才算 PD 链路通;直连后端 200 只证明单侧健康。

## 四、multi_node(Ray)要点

- head 节点容器内 `ray start --head --port 6379`,worker 节点 `ray start --address <head>:6379`,然后在 head `vllm serve --tensor-parallel-size <k×卡数>`(Ray 自动跨节点调度 worker)。
- 全部容器 host 网络 + 相同镜像;节点间 6379/8265 及 HCCL 数据面放通。
- worker 容器**不跑** vllm serve,只跑 ray;健康检查只探 head。
- A5 上跨节点 TP 通信同样需要 hixlep(同 pd 处理)。

## 五、形式确认后的固定化

部署形式 + 拓扑 + 节点分配表经 AskUserQuestion 确认后即为方案输入:
- 选定模板复制为专用产物,填充后**不再运行时切换**;
- 后续镜像/脚本/启动命令全部按该形式生成;
- 改形式 = 回到步骤 3 重新确认、重新生成产物。
