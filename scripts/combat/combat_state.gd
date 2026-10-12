class_name CombatState
extends RefCounted
## 角色动作状态枚举与优先级表（全局共享）。
##
## 为什么用集中枚举而不是每个脚本各自定义 bool：
##   1. 状态优先级是战斗手感的核心（"受击应该打断攻击"这类规则
##      需要一个统一的数值来比较，而不是散落在 if 里）
##   2. 调试面板可以打印状态名，一眼看出角色卡在哪
##   3. 网络同步只需要传一个 int，而不是一堆 bool

enum State {
	IDLE,          ## 站立/自由移动
	SPRINT,        ## 冲刺跑
	DODGE,         ## 闪避翻滚
	ATTACK,        ## 攻击中（含起手/有效/收招）
	CHARGE,        ## 蓄力中
	HITSTUN,       ## 受击硬直
	POISE_BREAK,   ## 架势被破（大硬直）
	EXECUTED,      ## 被处决
	DEAD,          ## 死亡
	DOWNED,        ## 倒地待救援（联机用）
	RESPAWNING,    ## 复活中
	VICTORY,       ## 胜利演出
	STAGGER_ATTACK ## 失衡攻击窗口（Boss 用）
}

## 状态优先级：数值越高越"不可被打断"。
## 例：HITSTUN(70) > ATTACK(50)，所以受击能打断攻击；
##     DEAD(100) 高于一切，死亡后不能再被任何状态覆盖。
const PRIORITY := {
	State.IDLE: 0,
	State.SPRINT: 0,
	State.DODGE: 40,
	State.ATTACK: 50,
	State.CHARGE: 50,
	State.STAGGER_ATTACK: 50,
	State.HITSTUN: 70,
	State.POISE_BREAK: 80,
	State.EXECUTED: 90,
	State.DOWNED: 85,
	State.RESPAWNING: 95,
	State.DEAD: 100,
	State.VICTORY: 100,
}

const NAMES := {
	State.IDLE: "待机",
	State.SPRINT: "冲刺",
	State.DODGE: "闪避",
	State.ATTACK: "攻击",
	State.CHARGE: "蓄力",
	State.HITSTUN: "受击硬直",
	State.POISE_BREAK: "架势破除",
	State.EXECUTED: "被处决",
	State.DEAD: "死亡",
	State.DOWNED: "倒地",
	State.RESPAWNING: "复活中",
	State.VICTORY: "胜利",
	State.STAGGER_ATTACK: "失衡攻击",
}


static func priority(s: State) -> int:
	return PRIORITY.get(s, 0)


static func state_name(s: State) -> String:
	return NAMES.get(s, "未知(%d)" % s)


## 该状态是否允许自由移动
static func allows_movement(s: State) -> bool:
	return s in [State.IDLE, State.SPRINT]


## 该状态是否是"已经出招、正在推进一个不可撤销的动作"
static func is_action_locked(s: State) -> bool:
	return s in [
		State.DODGE, State.ATTACK, State.CHARGE,
		State.HITSTUN, State.POISE_BREAK, State.EXECUTED,
		State.DEAD, State.DOWNED, State.RESPAWNING,
	]


## 该状态是否可以受到伤害（倒地和死亡除外）
static func can_take_damage(s: State) -> bool:
	return s not in [State.DEAD, State.DOWNED, State.RESPAWNING]
