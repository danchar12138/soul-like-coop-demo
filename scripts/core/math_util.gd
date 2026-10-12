class_name MathUtil
extends RefCounted
## 数学工具：集中处理本项目里最容易搞错的两件事——朝向角与平滑插值。
##
## 【为什么需要这个文件】
## Godot 的 Node3D 约定「前方 = -Z」。绕 Y 轴旋转 θ 后，
## 本地 -Z 轴在世界空间变为：
##     forward = (-sin θ, 0, -cos θ)
## 要让 forward 等于目标方向 d，必须解：
##     -sin θ = d.x,  -cos θ = d.z
##   => θ = atan2(-d.x, -d.z)
##
## 网上大量教程写的是 `rotation.y = atan2(d.x, d.z)`，那是给
## 「前方 = +Z」的模型（不少 GLTF 导出就是这样）用的。本项目所有
## 模型、判定盒偏移、移动基准都统一采用 -Z 前向，所以必须用
## 带负号的版本。
##
## 这个 bug 的症状非常隐蔽：角色看起来「在朝某处走」，但攻击判定盒
## 悬在背后，打不中人，而且镜头锁定后转向也怪。集中一处定义可以
## 避免以后再犯。

## 由水平方向向量求 Y 轴朝向角（弧度）。方向为 -Z 前向约定。
## direction 的 y 分量会被忽略。
static func yaw_from_direction(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


## 由两点求「从 from 指向 to」的朝向角
static func yaw_towards(from: Vector3, to: Vector3) -> float:
	return yaw_from_direction(to - from)


## 角度朝目标旋转，限制每次最大步长（弧度）
static func rotate_yaw_towards(current: float, target: float, max_step_rad: float) -> float:
	var diff := wrapf(target - current, -PI, PI)
	return current + clampf(diff, -max_step_rad, max_step_rad)


## 角度插值（自动走最短路径）
static func lerp_angle_weighted(from: float, to: float, weight: float) -> float:
	var diff := wrapf(to - from, -PI, PI)
	return from + diff * clampf(weight, 0.0, 1.0)


## 判断两个水平方向是否在给定夹角内
static func within_angle(a: Vector3, b: Vector3, tolerance_deg: float) -> bool:
	var ha := Vector3(a.x, 0.0, a.z)
	var hb := Vector3(b.x, 0.0, b.z)
	if ha.length_squared() < 0.0001 or hb.length_squared() < 0.0001:
		return true
	return rad_to_deg(ha.normalized().angle_to(hb.normalized())) <= tolerance_deg


## 把方向投影到水平面并归一化。零向量返回 Vector3.ZERO。
static func horizontal_normalized(v: Vector3) -> Vector3:
	var h := Vector3(v.x, 0.0, v.z)
	if h.length_squared() < 0.000001:
		return Vector3.ZERO
	return h.normalized()


## 球形均匀随机方向（碎片散射用）
static func random_unit_vector(rng: RandomNumberGenerator = null) -> Vector3:
	var r := rng if rng != null else null
	var z := randf_range(-1.0, 1.0) if r == null else r.randf_range(-1.0, 1.0)
	var a := randf_range(0.0, TAU) if r == null else r.randf_range(0.0, TAU)
	var r_xy := sqrt(maxf(0.0, 1.0 - z * z))
	return Vector3(r_xy * cos(a), z, r_xy * sin(a))
