extends Node
## 全局事件总线（Autoload 单例）。
##
## 设计意图：模块之间不直接互相持有引用，只通过信号通信。
## 例如 Boss 不需要知道 UI 存在，UI 只要监听 boss_health_changed。
##
## 命名约定：
##   *_requested —— 意图，可能被否决（例如精力不足）
##   *_started / *_finished —— 已确定发生的状态迁移
##   *_changed —— 数值变化，供 UI/调试订阅
##
## 注意：网络同步不靠 EventBus，靠 MultiplayerSynchronizer / RPC。
## EventBus 只服务本地表现层与 UI，不要用它传权威战斗结果。

# ---------- 战斗 ----------

## 一次攻击进入有效判定帧（本地表现层用，例如播放挥击音效）
signal attack_started(attacker: Node, attack_id: StringName)
## 攻击结束（含收招完成、被打断、取消）
signal attack_finished(attacker: Node, attack_id: StringName, reason: StringName)
## 攻击命中某目标。hit_position 为世界坐标，用于生成火花。
signal attack_landed(attacker: Node, target: Node, hit_position: Vector3, damage: float, weight: float)
## 攻击被格挡
signal attack_blocked(attacker: Node, target: Node, hit_position: Vector3)
## 攻击落空（有效帧结束但没有任何命中）
signal attack_whiffed(attacker: Node, attack_id: StringName)

## 任意单位受伤。用于飘字、音效、UI 血条。
signal damage_taken(target: Node, amount: float, remaining_health: float, is_heavy: bool)
## 任意单位死亡
signal entity_died(entity: Node, killer: Node)
## 单位开始受击硬直
signal hitstun_started(entity: Node, duration: float, is_heavy: bool)

## 架势（韧性）被打破，进入处决窗口
signal poise_broken(entity: Node, window_seconds: float)
## 架势恢复
signal poise_recovered(entity: Node)

# ---------- 精力 ----------

signal stamina_changed(entity: Node, current: float, maximum: float)
## 精力不足以执行某动作
signal stamina_insufficient(entity: Node, action: StringName)

# ---------- 玩家 ----------

signal player_spawned(player: Node, peer_id: int)
signal player_died(player: Node)
signal player_respawned(player: Node)
signal player_down_state_changed(player: Node, is_down: bool)

# ---------- 锁定 ----------

signal lock_on_changed(player: Node, target: Node)

# ---------- 地形破坏 ----------

## 可破坏物的耐久度变化
signal destructible_damaged(destructible: Node, current: float, maximum: float)
## 可破坏物被摧毁（authority 确认后广播）
signal destructible_destroyed(destructible_id: String, position: Vector3, piece_count: int)
## 可破坏物被修复/重置（检查点复活时用）
signal destructible_restored(destructible_id: String)

# ---------- Boss ----------

signal boss_phase_changed(boss: Node, phase: int)
signal boss_poise_changed(boss: Node, current: float, maximum: float)
signal boss_defeated(boss: Node)

# ---------- 会话/网络 ----------

signal session_started(is_host: bool)
signal session_ended()
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal net_error(message: String)

# ---------- 调试 ----------

signal debug_toggled(enabled: bool)
