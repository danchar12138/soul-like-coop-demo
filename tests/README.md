# 测试目录

所有测试都必须**实际执行**，结果由脚本自动生成，不允许手改。

## 快速运行

```bash
cd <项目根目录>

# 首次需要先导入资源
godot --headless --editor --quit

# 战斗系统集成测试（61 项）
godot --headless res://tests/test_runner.tscn

# 模型资源校验（25 项）
godot --headless res://tests/test_models.tscn

# 双进程联机连接测试
bash tests/run_net_test.sh

# 多进程多人战斗测试（2 人或 4 人）
bash tests/run_mp_battle_test.sh 2
bash tests/run_mp_battle_test.sh 4

# 性能测试（无头，测 CPU 逻辑/物理，不是真实 FPS）
bash tests/run_perf_test.sh

# 多人性能测试（同一台机器上的多个进程）
bash tests/run_mp_perf_test.sh 4
```

## 各测试的职责

| 文件 | 职责 | 结果文件 |
|------|------|----------|
| `test_runner.gd` | 战斗系统：攻击时序、命中判定、闪避无敌、精力、架势、连招、地形破坏、处决、死亡复活、Boss | `测试结果.txt`（自动生成） |
| `test_models.gd` | 模型资源：尺寸比例、朝向、三角面数、材质 | `模型校验结果.txt`（自动生成） |
| `net_test.gd` | 两个 Godot 进程之间的 ENet 连接与双向 RPC | 输出到标准输出 |
| `mp_battle_test.gd` | 多人战斗：玩家生成、Boss 同步、地形破坏同步 | 输出到标准输出 |
| `run_net_test.sh` | 启动两个进程跑 `net_test` | — |
| `run_mp_battle_test.sh` | 启动 1+N 个进程跑 `mp_battle_test` | `_mp_logs/*.log` |
| `perf_test.gd` | 性能：空场景 / 碎片满载 / 碎片静止对照 / Boss 战 / 最坏情况 / 连续破坏 8 个场景 | `性能结果.txt`（自动生成） |
| `perf_limit_probe.gd` | 上限探针：绕过池上限，找「碎片数量 → 物理耗时」的拐点（参考数据） | `性能上限探针.txt`（自动生成） |
| `perf_worst_probe.gd` | 最坏情况探针：60 个碎片全程飞行（限内理论最坏，参考数据） | `性能最坏情况探针.txt`（自动生成） |
| `mp_perf_test.gd` | 多人性能：每个进程各测自己的物理帧时间 | `_mp_perf/<role>_<pid>.txt` |
| `run_perf_test.sh` | 一键跑 `perf_test` + 两个探针（`--main-only` 只跑主测试） | — |
| `run_mp_perf_test.sh` | 启动 1+N 个进程跑 `mp_perf_test` | `_mp_perf/*` |

性能测试的完整分析与复现步骤见 `docs/性能报告.md`。
**注意**：无头（headless）模式用的是 dummy 渲染器，测不到 FPS 或渲染耗时，
上面几个性能测试测的都是 **CPU 逻辑与物理**，不是玩家看到的帧率。

## 为什么联机测试要开多个进程

Godot 的 `multiplayer` 单例每个 SceneTree 只有一份，
一个进程里无法同时扮演主机和客户端。所以必须真的开多个进程。

`run_mp_battle_test.sh 4` 启动的是 **4 个独立 Godot 进程**，
不是 4 台机器。这能验证同步逻辑、权限分配、状态一致性，
但**不能**验证真实网络延迟、丢包、NAT 穿透。
跨设备的测试步骤见 `docs/测试记录.md` 第五节。

## 测试设计上的几个坑（踩过所以记下来）

1. **lambda 按值捕获局部变量**：断言标志必须放成员变量上。
2. **`_process` 里 await 会让条件重复成立**：就绪标志要在 await **之前**置位。
3. **`queue_free` 是延迟释放**：遍历数组时必须同时判断
   `is_instance_valid` 和业务上的"已删除"标志。
4. **`PackedScene.pack()` 只打包 owner 指向根节点的子节点**：
   代码 `add_child` 不会自动设 owner，必须自己递归设置。
5. **RPC 按节点路径寻址**：对端节点还没建好时发消息会被丢弃，
   日志会刷 `Node not found`。要先做就绪握手。
6. **敌人 AI 必须被真正关掉**：有些敌人有"延迟自启"逻辑，
   测试里关掉后要防止它自己开回来（见 `EnemyBase.ai_enabled` 的 setter）。
