# -*- coding: utf-8 -*-
"""
带骨骼与蒙皮动画的角色生成脚本（Blender 后台模式）。

用法
----
在项目根目录执行：

    blender --background --python tools/blender_rig.py
    blender --background --python tools/blender_rig.py -- --preview

加 `--preview` 会额外渲染若干关键帧的预览图到
`assets/preview/`，用于人工核对姿态是否正确。

产物
----
  assets/models/player_rigged.glb   主角（骨骼 + 10 个动画）
  assets/blender/player_rigged.blend  可编辑源文件

为什么单独一个脚本，而不是加进 blender_assets.py
--------------------------------------------------
`blender_assets.py` 产出的是**静态网格**（低多边形、无骨骼），
作为"没有动画时的占位美术"仍然有效。

骨骼动画是完全不同的工序：需要建骨架、蒙皮、逐帧设关键帧、
调整各个动作的时长以匹配战斗配置。混在一起会让两个脚本都变得难以阅读。
所以拆开，各自独立可跑。

产物文件名也不同（`player_rigged.glb`），`build_scenes.gd` 会
优先用它，找不到才回退到静态的 `player.glb`。

动画时长必须与战斗配置对齐
--------------------------
这不是可选项。`AttackData` 里定义了每条攻击的
起手 / 有效 / 收招时长，动画必须**在同一时刻**完成对应的姿态变化，
否则会出现"判定已经打出去了但刀还没挥到"这种致命的错位。

所以本脚本的动画定义直接读 `resources/weapons/katana.tres` 之外的
一份**手工同步的时长表**（见 ATTACK_TIMINGS），并在导出前断言
它与 `tools/generate_weapons.gd` 里的数值一致。
改攻击数值时，两边都要改，脚本会提示。

姿态描述方式
------------
骨骼姿态用"**骨骼在世界空间中指向哪个方向**"来描述，而不是
欧拉角。原因：

  1. 欧拉角依赖骨骼的局部坐标系，而局部坐标系由 head/tail 与 roll
     共同决定，很难凭直觉写对，写错了要反复试。
  2. "上臂指向斜下方"这种描述是所见即所得的，调姿态时不必
     在脑子里做三次坐标变换。
  3. 可以直接把"刀尖扫过目标"表达成手腕骨骼的朝向。

实现见 `BonePoser`：它把方向转换成 pose bone 的局部矩阵。
"""

import math
import os
import sys

try:
    import bpy
    from mathutils import Vector, Matrix, Euler
except ImportError:
    print("[错误] 本脚本必须在 Blender 的 Python 环境中运行。")
    print("       请使用: blender --background --python tools/blender_rig.py")
    sys.exit(1)


# ============================================================
# 路径与常量
# ============================================================

def _project_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(here)


ROOT = _project_root()
BLEND_DIR = os.path.join(ROOT, "assets", "blender")
MODEL_DIR = os.path.join(ROOT, "assets", "models")
PREVIEW_DIR = os.path.join(ROOT, "assets", "preview")

## 动画帧率。30 与多数游戏动画一致，且换算成秒很直观（1 帧 = 1/30 秒）。
FPS = 30

## 输出文件名
OUT_GLB = "player_rigged.glb"
OUT_BLEND = "player_rigged.blend"


def log(msg: str) -> None:
    print(msg)


# ============================================================
# 战斗时序表（必须与 tools/generate_weapons.gd 保持一致）
# ============================================================
#
# 这里冗余记录了一份攻击时序。为什么要冗余：
#   Blender 的 Python 环境里读不到 Godot 的 .tres 资源（那是 Godot 的
#   序列化格式），所以无法自动同步。与其悄悄用一组可能与游戏不符的
#   数值生成动画，不如显式记录并**在导出前断言**，数值对不上就报错。
#
# 每条：(起手, 有效, 收招, 伤害) 单位：秒
ATTACK_TIMINGS = {
    "idle":            None,                                  # 循环，无时序
    "run":             None,                                  # 循环
    "katana_light_1":  (0.30, 0.10, 0.34, 18.0),
    "katana_light_2":  (0.26, 0.10, 0.36, 21.0),
    "katana_light_3":  (0.42, 0.14, 0.52, 30.0),
    "katana_heavy":    (0.55, 0.14, 0.60, 45.0),
    "katana_iai":      (0.22, 0.16, 0.74, 80.0),
    "katana_dodge_attack": (0.20, 0.10, 0.46, 24.0),
    "katana_execution": (0.50, 0.10, 0.75, 260.0),
    "dodge":           None,                                  # 用 PlayerController 的闪避时长
    "hit_light":       ("hit",),
    "hit_heavy":       ("hit",),
    "death":           None,
    "poise_break":     None,
}

## 与 GameConfig 里对应（同样需要手工同步）
DODGE_DURATION = 0.62
HITSTUN_LIGHT = 0.32
HITSTUN_HEAVY = 0.72


# ============================================================
# 骨架定义
# ============================================================
#
# 坐标约定（Blender，Z 向上、Y 向前）：
#   角色面向 +Y —— 导出到 Godot 后即为 -Z 前向。
#   理由见 tools/blender_assets.py 顶部的推导。
#
# 每条：(骨骼名, 父骨骼, head 坐标, tail 坐标)
# 角色身高约 1.80 m。骨骼位置按人体比例放置，且要让自动权重
# 能得到合理结果 —— 骨骼必须**落在网格内部**，否则自动权重会把
# 顶点分配给错误的骨骼。
BONES = [
    # 根与躯干
    ("Root",        None,      (0.00, 0.00, 0.00), (0.00, 0.00, 0.10)),
    ("Hips",        "Root",    (0.00, 0.00, 0.92), (0.00, 0.00, 1.02)),
    ("Spine",       "Hips",    (0.00, 0.00, 1.02), (0.00, 0.00, 1.28)),
    ("Chest",       "Spine",   (0.00, 0.00, 1.28), (0.00, 0.00, 1.50)),
    ("Neck",        "Chest",   (0.00, 0.00, 1.50), (0.00, 0.00, 1.60)),
    ("Head",        "Neck",    (0.00, 0.00, 1.60), (0.00, 0.00, 1.80)),

    # 左臂（角色的左手 = -X 侧）
    ("Shoulder.L",  "Chest",   (0.06, 0.00, 1.45), (0.20, 0.00, 1.44)),
    ("UpperArm.L",  "Shoulder.L", (0.20, 0.00, 1.44), (0.25, 0.00, 1.16)),
    ("LowerArm.L",  "UpperArm.L", (0.25, 0.00, 1.16), (0.27, 0.00, 0.92)),
    ("Hand.L",      "LowerArm.L", (0.27, 0.00, 0.92), (0.27, 0.00, 0.80)),

    # 右臂（持刀手）
    ("Shoulder.R",  "Chest",   (-0.06, 0.00, 1.45), (-0.20, 0.00, 1.44)),
    ("UpperArm.R",  "Shoulder.R", (-0.20, 0.00, 1.44), (-0.25, 0.00, 1.16)),
    ("LowerArm.R",  "UpperArm.R", (-0.25, 0.00, 1.16), (-0.27, 0.00, 0.92)),
    ("Hand.R",      "LowerArm.R", (-0.27, 0.00, 0.92), (-0.27, 0.00, 0.80)),

    # 左腿
    ("UpperLeg.L",  "Hips",    (0.11, 0.00, 0.90), (0.11, 0.00, 0.50)),
    ("LowerLeg.L",  "UpperLeg.L", (0.11, 0.00, 0.50), (0.11, 0.00, 0.10)),
    ("Foot.L",      "LowerLeg.L", (0.11, 0.00, 0.10), (0.11, 0.18, 0.03)),

    # 右腿
    ("UpperLeg.R",  "Hips",    (-0.11, 0.00, 0.90), (-0.11, 0.00, 0.50)),
    ("LowerLeg.R",  "UpperLeg.R", (-0.11, 0.00, 0.50), (-0.11, 0.00, 0.10)),
    ("Foot.R",      "LowerLeg.R", (-0.11, 0.00, 0.10), (-0.11, 0.18, 0.03)),

    # 太刀（挂在右手上，方便整把刀跟着手走）
    ("Katana",      "Hand.R",  (-0.27, 0.00, 0.80), (-0.27, 0.10, 0.80)),
]


# ============================================================
# 姿态系统：用「骨骼指向哪个方向」来定义姿态
# ============================================================

## 世界坐标的常用方向（Blender 空间：Z 向上、Y 向前）
FWD = Vector((0.0, 1.0, 0.0))      # 角色正前方
BACK = Vector((0.0, -1.0, 0.0))
UP = Vector((0.0, 0.0, 1.0))
DOWN = Vector((0.0, 0.0, -1.0))
LEFT = Vector((1.0, 0.0, 0.0))
RIGHT = Vector((-1.0, 0.0, 0.0))

## 姿态里这个值表示"保持该骨骼的静止朝向"。
##
## 用途：像躯干这样本来就朝着正确方向的骨骼，我们只想给它加一点倾斜，
## 而不是指定一个绝对方向。用 `REST` 占位，由 BonePoser 替换成该骨骼
## 真正的静止方向，再与给定的偏转角叠加。
##
## 【为什么躯干必须用 tilt() 而不是手写方向向量 —— 一个真实的坑】
## 骨骼的"静止上方向"（rest_up，即局部 Z 轴）各不相同：
##   Hips / Spine / Chest / Neck / Head -> (0, -1, 0)，朝后
##   UpperArm / LowerArm / Hand        -> 大致朝后或朝上
##   腿骨                              -> (0, 1, 0)，朝前
##
## 手写 `(dir3(0, 0.08, 1.0), FWD)` 给躯干时，"上方向"参考被指定成
## FWD = (0,1,0)，与静止上方向 (0,-1,0) **正好相反**。
## 于是叉乘算出来的基向量翻转了，骨骼被拧了 180 度 ——
## 预览图里躯干变成上下颠倒的漏斗、四肢扭曲。
##
## tilt() 不传上方向参考，BonePoser 就会用该骨骼自己的静止上方向，
## 结果稳定。腿骨用 `(方向, FWD)` 是安全的，因为腿的静止上方向
## 本来就是 FWD。
REST = "REST"


def tilt(yaw_deg: float = 0.0, pitch_deg: float = 0.0) -> tuple:
    """描述一个"相对静止朝向"的倾斜。

    yaw_deg   正数 = 向左转（绕世界 Z 轴，右手法则）
    pitch_deg 正数 = 向前倾

    返回一个特殊元组，由 BonePoser 解释。
    这样躯干姿态就不必手写方向向量 —— 手写方向向量时很容易把
    "躯干朝上"误写成别的方向，导致整个身体被拧成漏斗状。
    """
    return (REST, yaw_deg, pitch_deg)


def dir3(x: float, y: float, z: float) -> Vector:
    """构造一个归一化的方向向量，便于书写。"""
    v = Vector((x, y, z))
    if v.length < 1e-6:
        return FWD.copy()
    return v.normalized()


class BonePoser:
    """把「骨骼朝向」翻译成 pose bone 的矩阵。

    为什么不用欧拉角直接写：

      Blender 的 pose bone 旋转是**局部空间**的，而局部空间由骨骼的
      head/tail 方向和 roll 共同决定。对竖着的腿骨，"向前踢"可能是
      绕局部 X，对横着的手臂，"向前伸"可能又是另一个轴 —— 每次都要
      在脑子里做坐标变换，极易写错且很难调试。

      改成"我希望这根骨头在世界里指向这个方向"之后，姿态描述就变成
      所见即所得的，调参时可以直接对着预览图改。

    实现要点（这里有一个必须踩过才知道的坑）：

      `pose_bone.matrix` 是骨骼在 armature 空间的姿态矩阵。给它赋值时，
      Blender 会用**当前的**父骨骼姿态反算出局部旋转（matrix_basis）。

      问题是：如果在同一次循环里连续设置父骨骼和子骨骼的 matrix，
      父骨骼的新姿态还没被 depsgraph 求值，子骨骼读到的仍是旧的父级
      矩阵 —— 反算出来的局部旋转就是错的。症状是姿态整体扭曲、
      骨骼被拉长成漏斗状。

      所以必须在**每设置一根骨骼之后**调用 `view_layer.update()`，
      强制重新求值。21 根骨骼 × 每个关键帧一次，代价可以接受
      （实测整个脚本仍在几秒内跑完）。
    """

    def __init__(self, armature_obj):
        self.arm = armature_obj
        ## 每根骨骼的静止方向与静止上方向（armature 空间）
        self.rest_dir = {}
        self.rest_up = {}
        for bone in armature_obj.data.bones:
            m = bone.matrix_local.to_3x3()
            # 骨骼局部 Y 轴 = head -> tail
            self.rest_dir[bone.name] = (m @ Vector((0.0, 1.0, 0.0))).normalized()
            # 骨骼局部 Z 轴 = 静止时的"上方向"。
            # 用它当默认参考，可以让"把骨骼摆回静止方向"得到恒等旋转，
            # 避免不必要地引入 180 度翻滚。
            self.rest_up[bone.name] = (m @ Vector((0.0, 0.0, 1.0))).normalized()

    def reset(self) -> None:
        """把所有骨骼恢复到静止姿态。"""
        for pb in self.arm.pose.bones:
            pb.location = (0.0, 0.0, 0.0)
            pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
            pb.rotation_euler = (0.0, 0.0, 0.0)
            pb.scale = (1.0, 1.0, 1.0)
            pb.rotation_mode = 'QUATERNION'
        bpy.context.view_layer.update()

    def apply(self, pose: dict) -> None:
        """应用一个姿态。

        pose 的格式：
            {
              "UpperArm.R": (方向向量, 可选的上方向, 可选的世界位移偏移),
              ...
            }

        未在字典里出现的骨骼保持静止姿态。
        按 BONES 的拓扑顺序处理，且**每根骨骼设置完立刻求值**，
        保证子骨骼读到的父级矩阵是最新的。
        """
        self.reset()

        for name, _parent, _head, _tail in BONES:
            if name not in pose:
                continue
            pb = self.arm.pose.bones.get(name)
            if pb is None:
                continue

            entry = pose[name]
            fwd = entry[0]
            up_hint = entry[1] if len(entry) > 1 and entry[1] is not None else None
            offset = entry[2] if len(entry) > 2 else None

            self._set_bone(pb, fwd, up_hint, offset)

            # 关键：立刻求值。少了这一句，后面设置子骨骼时会用到过期的
            # 父级矩阵，姿态整体错位（见类文档的说明）。
            bpy.context.view_layer.update()

    def _set_bone(self, pb, fwd_world, up_hint, offset) -> None:
        # --- 解析方向 ---
        # 支持两种写法：
        #   一个方向向量        -> 绝对指定骨骼朝向
        #   tilt(yaw, pitch)    -> 在骨骼的**静止朝向**基础上叠加倾斜
        # 后者用于躯干：手写躯干方向向量时极易写偏，导致身体整体扭曲。
        if isinstance(fwd_world, tuple) and len(fwd_world) == 3 \
                and fwd_world[0] == REST:
            _, yaw_deg, pitch_deg = fwd_world
            rest = self.rest_dir.get(pb.name, UP)
            up_ref = self.rest_up.get(pb.name, FWD)
            yaw = math.radians(yaw_deg)
            pitch = math.radians(pitch_deg)
            # 先绕世界 UP 转 yaw（侧倾），再绕"右"轴转 pitch（前倾）
            rot_yaw = Matrix.Rotation(yaw, 3, 'Z')
            side = rest.cross(up_ref)
            if side.length < 1e-5:
                side = LEFT
            side.normalize()
            rot_pitch = Matrix.Rotation(pitch, 3, side)
            fwd = (rot_pitch @ rot_yaw @ rest).normalized()
        else:
            fwd = Vector(fwd_world)
            if fwd.length < 1e-6:
                fwd = self.rest_dir.get(pb.name, UP)
            fwd = fwd.normalized()

        # 参考上方向：优先用调用方给的；否则用该骨骼**静止时的** Z 轴。
        # 用静止 Z 轴而不是"世界 UP"很重要 —— 手臂这类骨骼静止时是横着
        # 指的，用世界 UP 当参考会引入一个 90 度的翻转。
        if up_hint is not None:
            up = Vector(up_hint).normalized()
        else:
            up = self.rest_up.get(pb.name, UP)

        # 参考向量与骨骼指向过于接近时，叉乘会退化成零向量
        if abs(fwd.dot(up)) > 0.995:
            up = self.rest_dir.get(pb.name, UP)
            if abs(fwd.dot(up)) > 0.995:
                up = LEFT if abs(fwd.dot(LEFT)) < 0.9 else UP

        right = fwd.cross(up)
        if right.length < 1e-5:
            right = fwd.cross(UP)
        right.normalize()
        up = right.cross(fwd).normalized()

        # 骨骼局部轴向：X = right, Y = fwd, Z = up
        basis = Matrix((
            (right.x, fwd.x, up.x),
            (right.y, fwd.y, up.y),
            (right.z, fwd.z, up.z),
        )).to_4x4()

        target = basis
        target.translation = pb.matrix.translation.copy()
        if offset is not None:
            target.translation = target.translation + Vector(offset)

        pb.matrix = target


# ============================================================
# 骨架与网格构建
# ============================================================

def build_armature():
    """创建骨架对象。返回 armature object。"""
    bpy.ops.object.armature_add(enter_editmode=False, location=(0.0, 0.0, 0.0))
    arm_obj = bpy.context.active_object
    arm_obj.name = "PlayerArmature"
    arm_obj.data.name = "PlayerRig"

    bpy.ops.object.mode_set(mode='EDIT')
    ebs = arm_obj.data.edit_bones
    # 清掉默认那根骨头
    for b in list(ebs):
        ebs.remove(b)

    created = {}
    for name, parent, head, tail in BONES:
        eb = ebs.new(name)
        eb.head = Vector(head)
        eb.tail = Vector(tail)
        # roll = 0：让局部 Z 轴尽量朝向世界 -Y（Blender 的默认行为）。
        # 我们反正用方向驱动姿态，roll 只影响扭转自由度的解释。
        eb.roll = 0.0
        if parent and parent in created:
            eb.parent = created[parent]
            # 不启用 connect：允许子骨骼的 head 与父骨骼的 tail 不完全重合，
            # 这样关节位置更自由（例如肩胛骨与上臂）。
            eb.use_connect = False
        created[name] = eb

    bpy.ops.object.mode_set(mode='OBJECT')

    for pb in arm_obj.pose.bones:
        pb.rotation_mode = 'QUATERNION'

    log("    骨架：%d 根骨骼" % len(arm_obj.data.bones))
    return arm_obj


def build_mesh_body():
    """构建要蒙皮的身体网格。

    与静态版的区别：
      1. 部件**更细**（手臂分上臂/前臂，腿分大腿/小腿），
         因为蒙皮需要足够的顶点密度才能变形。
      2. 每个部件在创建时就**标记好它属于哪根骨骼**（通过顶点组）。
         合并时 Blender 会按组名合并顶点组，于是合并后
         每个顶点自动落在正确的组里。

    为什么要用这种"按部件指定骨骼"的方式，而不是按距离自动分配 ——
    见 `_skin_by_part()` 的说明。简单说：胸口的方块离肩骨比离胸骨更近，
    按距离分配会把胸腔顶点分给手臂，抬手时胸腔被拉成梯形。
    """
    parts = []

    def mk_box(name, size, loc, bone: str, rot=(0.0, 0.0, 0.0)):
        bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
        o = bpy.context.active_object
        o.name = name
        o.scale = size
        o.rotation_euler = rot
        _mark_part(o, bone)
        parts.append(o)
        return o

    def mk_cyl(name, r, h, loc, bone: str, verts=8, rot=(0.0, 0.0, 0.0)):
        bpy.ops.mesh.primitive_cylinder_add(
            vertices=verts, radius=r, depth=h, location=loc)
        o = bpy.context.active_object
        o.name = name
        o.rotation_euler = rot
        _mark_part(o, bone)
        parts.append(o)
        return o

    # 躯干：分三段（髋 / 腰 / 胸），让脊柱弯曲时能平滑过渡
    mk_box("Pelvis", (0.30, 0.20, 0.22), (0.0, 0.0, 0.98), "Hips")
    mk_box("Waist", (0.28, 0.19, 0.22), (0.0, 0.0, 1.18), "Spine")
    mk_box("Chest", (0.38, 0.22, 0.26), (0.0, 0.0, 1.42), "Chest")
    mk_box("ChestPlate", (0.30, 0.14, 0.16), (0.0, 0.13, 1.44), "Chest")

    # 颈与头
    mk_cyl("Neck", 0.075, 0.12, (0.0, 0.0, 1.56), "Neck", verts=6)
    mk_box("Head", (0.20, 0.21, 0.22), (0.0, 0.0, 1.71), "Head")
    mk_box("Visor", (0.21, 0.06, 0.05), (0.0, 0.10, 1.73), "Head")

    # 手臂：上臂 / 前臂 / 手 各一段
    for tag, sx in (("L", 1.0), ("R", -1.0)):
        mk_cyl("Shoulder" + tag, 0.085, 0.14,
               (sx * 0.17, 0.0, 1.44), "Shoulder." + tag,
               verts=6, rot=(0.0, math.pi * 0.5, 0.0))
        mk_cyl("UpperArm" + tag, 0.062, 0.30,
               (sx * 0.225, 0.0, 1.30), "UpperArm." + tag, verts=6)
        mk_cyl("LowerArm" + tag, 0.054, 0.26,
               (sx * 0.26, 0.0, 1.04), "LowerArm." + tag, verts=6)
        mk_box("Hand" + tag, (0.08, 0.075, 0.10),
               (sx * 0.27, 0.0, 0.86), "Hand." + tag)

    # 腿：大腿 / 小腿 / 脚
    for tag, sx in (("L", 1.0), ("R", -1.0)):
        mk_cyl("UpperLeg" + tag, 0.085, 0.42,
               (sx * 0.11, 0.0, 0.70), "UpperLeg." + tag, verts=6)
        mk_cyl("LowerLeg" + tag, 0.070, 0.42,
               (sx * 0.11, 0.0, 0.30), "LowerLeg." + tag, verts=6)
        mk_box("Foot" + tag, (0.10, 0.22, 0.075),
               (sx * 0.11, 0.05, 0.04), "Foot." + tag)

    # 合并成一个网格对象：蒙皮要求顶点在同一个对象里。
    #
    # 合并前必须 transform_apply：各部件是用 object.scale 设置的尺寸，
    # 那个缩放还没烘焙进顶点数据。不烘焙的话 Blender 会在导出时警告
    # 「Mesh ... is not valid」，法线也可能不正确。
    bpy.ops.object.select_all(action='DESELECT')
    for o in parts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    bpy.ops.object.join()
    body = bpy.context.active_object
    body.name = "PlayerBody"
    body.data.name = "PlayerBodyMesh"
    body.data.validate()

    # 注意：这里**不**统一覆盖材质 —— 各部件在 _mark_part 里已经
    # 按部位分配了颜色，join 之后网格带多个材质槽。
    for poly in body.data.polygons:
        poly.use_smooth = False

    log("    网格：%d 个顶点，%d 个面，%d 个部件组，%d 个材质槽" % (
        len(body.data.vertices), len(body.data.polygons),
        len(body.vertex_groups), len(body.data.materials)))
    return body


## 部件配色。键是部件名的前缀，值是 sRGB 十六进制色。
##
## 用"每个部件一个材质"而不是统一一个灰色材质：
## 低多边形风格靠**色块**来读形状，纯灰的模型在游戏里看起来像
## 未完成的占位体。上色后能一眼分辨躯干、四肢、护甲、布料。
##
## 材质数量控制在 5 个以内：glTF 会为每个材质生成一个 draw call，
## 5 个材质意味着每个角色 5 次绘制调用 —— 四人联机时 20 次，
## 完全可接受。再多就该考虑合并成一张贴图了。
PART_COLORS = [
    ("Head",       "#D8CEC0"),   # 头部：肤色偏亮
    ("Visor",      "#3A3A42"),   # 面罩：深色
    ("ChestPlate", "#5E6472"),   # 胸甲：冷灰
    ("Chest",      "#8E94A2"),   # 胸腔：亮灰
    ("Waist",      "#7A8090"),   # 腰
    ("Pelvis",     "#6B7181"),   # 髋 / 战裙
    ("Shoulder",   "#5E6472"),   # 肩甲
    ("UpperArm",   "#8E94A2"),
    ("LowerArm",   "#8E94A2"),
    ("Hand",       "#4A4F5C"),   # 手：深色（像护手）
    ("UpperLeg",   "#5C6270"),
    ("LowerLeg",   "#5C6270"),
    ("Foot",       "#41454F"),
    ("Neck",       "#6E7484"),
]


def _material_for(name: str):
    """按部件名前缀取（并缓存）材质。"""
    for prefix, hexcolor in PART_COLORS:
        if name.startswith(prefix):
            key = "Part_" + prefix
            mat = bpy.data.materials.get(key)
            if mat is None:
                mat = _make_part_material(key, hexcolor)
            return mat
    # 兜底
    return _make_part_material("Part_Default", "#8E94A2")


def _make_part_material(name: str, hexcolor: str):
    """建立一个低多边形风格的基础材质（纯色 + 高粗糙度）。

    同时设置两处颜色：
      1. `Principled BSDF` 的 Base Color —— 这是**导出到 glTF** 的颜色，
         游戏里看到的就是它。
      2. `mat.diffuse_color` —— 这是 Blender **视口显示**用的颜色。
         Workbench 渲染引擎（预览图用的那个）只读这个值，
         不读节点树。不设置的话预览图会全是灰的，
         没法用来核对配色。
    """
    linear = _srgb_to_linear(hexcolor)
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = linear
        bsdf.inputs["Roughness"].default_value = 0.85
        bsdf.inputs["Metallic"].default_value = 0.0
    mat.diffuse_color = linear
    mat.roughness = 0.85
    return mat


def _srgb_to_linear(hexcolor: str):
    """sRGB 十六进制 -> Blender 需要的线性浮点 RGBA。

    直接除以 255 会让颜色偏亮（Blender 的 Base Color 是线性空间），
    所以要做标准的 sRGB -> 线性转换。
    """
    h = hexcolor.lstrip("#")
    out = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255.0
        c = c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
        out.append(c)
    return (out[0], out[1], out[2], 1.0)


def _mark_part(obj, bone: str) -> None:
    """把某个部件的所有顶点标记为属于指定骨骼，并按部件名分配材质。

    顶点组：
      在该部件上建一个以骨骼名命名的顶点组，全部权重 1.0。
      `join()` 会按组名合并顶点组，所以合并之后每个顶点自然落在
      正确的骨骼组里 —— 相当于一份"按部件划分的精确权重表"。

      这比按距离自动分配可靠得多：自动分配会让胸口的方块（离肩骨只有
      0.16 m，离胸骨 0.22 m）被判给手臂，抬手时胸腔被拉成梯形。

    材质：
      按名字前缀取一个纯色材质。`join()` 会把各对象的材质槽合并起来，
      合并后的网格带多个材质槽，glTF 会导出成多个 primitive。
    """
    vg = obj.vertex_groups.new(name=bone)
    vg.add([v.index for v in obj.data.vertices], 1.0, 'REPLACE')

    obj.data.materials.clear()
    obj.data.materials.append(_material_for(obj.name))


## 太刀网格挂载点。
##
## **必须与骨架里 Katana 骨骼的 head 完全一致。**
##
## 因为太刀是刚性绑定（100% 权重给 Katana 骨骼），网格会随该骨骼的
## 变换增量一起移动。如果建模时把刀放在原点、而骨骼在别处，
## 每根骨骼变换都会把刀**平移**骨骼位移的量 ——
## 症状是刀完全脱离手，飘在身体旁边乱转。
##
## 这个位置 = Hand.R 骨骼的 tail = Katana 骨骼的 head（右手掌心）。
KATANA_ATTACH = Vector((-0.27, 0.00, 0.80))


def build_katana():
    """构建太刀网格（作为独立对象，蒙皮到 Katana 骨骼）。

    为什么武器单独一个对象：
      武器是刚体，不需要形变。把它和身体合并会让顶点组按名字合并时
      把刀也归到 Hand.R 组，挥刀时刀柄会被手骨的形变拉伸。

    建模基准：网格沿 **+Y** 延伸（与 Katana 骨骼的静止指向一致），
    握持点（刀柄中心）位于 `KATANA_ATTACH`。
    """
    parts = []
    ox, oy, oz = KATANA_ATTACH

    def mk_box(name, size, loc):
        bpy.ops.mesh.primitive_cube_add(
            size=1.0, location=(ox + loc[0], oy + loc[1], oz + loc[2]))
        o = bpy.context.active_object
        o.name = name
        o.scale = size
        parts.append(o)
        return o

    # 刀柄（握持点在它的中心附近）
    mk_box("Grip", (0.032, 0.24, 0.042), (0.0, 0.02, 0.0))
    # 护手
    mk_box("Guard", (0.075, 0.02, 0.075), (0.0, 0.15, 0.0))
    # 刀身
    mk_box("Blade", (0.026, 0.72, 0.060), (0.0, 0.53, 0.0))
    # 刀尖
    mk_box("BladeTip", (0.021, 0.14, 0.045), (0.0, 0.95, 0.0))

    bpy.ops.object.select_all(action='DESELECT')
    for o in parts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    bpy.ops.object.join()
    blade = bpy.context.active_object
    blade.name = "Katana"
    blade.data.name = "KatanaMesh"
    blade.data.validate()

    mat = bpy.data.materials.new("KatanaSteel")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        # 刀身用亮金属色：与身体的哑光灰形成对比，
        # 让"刀在哪"在任何背景下都能一眼看清（战斗可读性）
        steel = _srgb_to_linear("#C8CDD6")
        bsdf.inputs["Base Color"].default_value = steel
        bsdf.inputs["Roughness"].default_value = 0.28
        bsdf.inputs["Metallic"].default_value = 0.80
        mat.diffuse_color = steel
        mat.roughness = 0.28
        mat.metallic = 0.80
    blade.data.materials.clear()
    blade.data.materials.append(mat)

    for poly in blade.data.polygons:
        poly.use_smooth = False

    return blade


def bind_meshes(arm_obj, body, blade) -> None:
    """把网格绑定到骨架。

    身体：用建模阶段就写好的"按部件划分"的顶点组（见 `_mark_part`），
          再补一层关节处的平滑过渡（见 `_skin_by_part`）。

    **不用 Blender 的自动权重（ARMATURE_AUTO）。** 两条理由，都是实测出来的：

      1. 自动权重是"骨骼热量扩散"，要求网格近似连通。本角色是若干
         **互相分离**的方块与圆柱拼成的，热量传不到所有顶点 ——
         实测 212 个顶点里有 32 个完全没有权重，挥刀时会有整块身体
         留在原地不动。
      2. 即使传到了，按距离分配也不符合预期：胸口的方块离肩骨
         (0.16 m) 比离胸骨 (0.22 m) 更近，会被判给手臂，
         抬手时胸腔被拉成梯形。

    太刀：整体绑到 Katana 骨骼（刚体，不应有任何混合权重）。
    """
    _skin_by_part(arm_obj, body)
    _skin_rigid(arm_obj, blade, "Katana")


def _skin_by_part(arm_obj, mesh_obj) -> None:
    """基于"部件 -> 骨骼"的顶点组做蒙皮，并在关节处做平滑。

    建模时每个部件已经标好了它属于哪根骨骼，所以这里只需要
    在**关节附近**加一点混合，让弯曲时两块几何体平滑过渡而不是硬切。

    做法：对每个顶点，如果它同时靠近"自己的骨骼"和"父骨骼"的关节，
    就按距离在两个组之间做混合。混合范围由 `BLEND_RADIUS` 控制。
    只处理一层父子关系 —— 对手指粗细的低多边形角色，这就够了，
    再复杂的权重肉眼也看不出来。
    """
    BLEND_RADIUS = 0.11      # 关节混合半径（米）

    # 建立 骨骼名 -> (本骨骼线段, 父骨骼名, 父骨骼线段)
    bone_by_name = {b.name: b for b in arm_obj.data.bones}

    groups = {g.name: g for g in mesh_obj.vertex_groups}
    # 记下每个顶点"原本属于哪根骨骼"
    original = {}
    for v in mesh_obj.data.vertices:
        for g in v.groups:
            if g.weight > 0.5:
                original[v.index] = mesh_obj.vertex_groups[g.group].name
                break

    obj_matrix = mesh_obj.matrix_world
    blended = 0

    for v in mesh_obj.data.vertices:
        own = original.get(v.index)
        if own is None or own not in bone_by_name:
            continue
        parent_name = bone_by_name[own].parent.name if bone_by_name[own].parent else None
        if parent_name is None or parent_name not in bone_by_name:
            continue

        world_co = obj_matrix @ v.co
        own_bone = bone_by_name[own]
        par_bone = bone_by_name[parent_name]

        # 关节位置 = 本骨骼的头部
        joint = own_bone.head_local
        d_joint = (world_co - joint).length
        if d_joint > BLEND_RADIUS:
            continue

        # 在混合半径内，按位置在父/子之间过渡。
        # 用平滑曲线（smoothstep）而不是线性，避免过渡带边缘出现折痕。
        t = d_joint / BLEND_RADIUS          # 0 = 贴着关节，1 = 到混合边缘
        t = t * t * (3.0 - 2.0 * t)
        # t 越大越靠近自己的骨骼
        parent_weight = 0.5 * (1.0 - t)
        own_weight = 1.0 - parent_weight

        if own in groups:
            groups[own].add([v.index], own_weight, 'REPLACE')
        if parent_name in groups:
            groups[parent_name].add([v.index], parent_weight, 'REPLACE')
        else:
            # 父骨骼没有组（例如 Hips 的父级 Root 被排除），
            # 那就把自己补满，避免权重和不为 1
            if own in groups:
                groups[own].add([v.index], 1.0, 'REPLACE')
        blended += 1

    # 挂上骨架修改器。注意这里**不**用 parent_set ——
    # 那会重新触发自动权重，把我们刚算好的组覆盖掉。
    for mod in list(mesh_obj.modifiers):
        if mod.type == 'ARMATURE':
            mesh_obj.modifiers.remove(mod)
    mod = mesh_obj.modifiers.new(name="Armature", type='ARMATURE')
    mod.object = arm_obj
    mesh_obj.parent = arm_obj
    mesh_obj.matrix_parent_inverse = arm_obj.matrix_world.inverted()

    _verify_weights(mesh_obj, blended)


def _verify_weights(mesh_obj, blended: int) -> None:
    """自检：确认没有孤儿顶点、权重和都归一到 1、影响骨骼数不超限。

    这三条任何一条不满足都会在游戏里表现为"某块身体不动"或
    "形变幅度不对"，而且很难从渲染结果反推出原因，所以在这里挡掉。
    """
    orphans = 0
    bad_sum = 0
    max_bones = 0
    for v in mesh_obj.data.vertices:
        if not v.groups:
            orphans += 1
            continue
        s = sum(g.weight for g in v.groups)
        if abs(s - 1.0) > 0.01:
            bad_sum += 1
        max_bones = max(max_bones, len(v.groups))

    log("    蒙皮：%d 个顶点，其中 %d 个在关节混合带内" % (
        len(mesh_obj.data.vertices), blended))
    log("    每顶点最多影响 %d 根骨骼（glTF 上限 4）" % max_bones)
    if orphans > 0:
        log("    [错误] 有 %d 个顶点没有权重 —— 它们会在动画中完全不动" % orphans)
    else:
        log("    自检：无孤儿顶点")
    if bad_sum > 0:
        log("    [错误] 有 %d 个顶点的权重和不为 1 —— 形变幅度会不对" % bad_sum)
    else:
        log("    自检：权重和均为 1")
    if max_bones > 4:
        log("    [错误] 有顶点影响超过 4 根骨骼，导出时会被截断")


def _skin_rigid(arm_obj, mesh_obj, bone_name: str) -> None:
    """把整个网格按 100% 权重绑到单根骨骼上（用于武器这类刚体）。"""
    mesh_obj.vertex_groups.clear()
    vg = mesh_obj.vertex_groups.new(name=bone_name)
    vg.add([v.index for v in mesh_obj.data.vertices], 1.0, 'REPLACE')

    for mod in list(mesh_obj.modifiers):
        if mod.type == 'ARMATURE':
            mesh_obj.modifiers.remove(mod)
    mod = mesh_obj.modifiers.new(name="Armature", type='ARMATURE')
    mod.object = arm_obj
    mesh_obj.parent = arm_obj
    mesh_obj.matrix_parent_inverse = arm_obj.matrix_world.inverted()


def _point_to_segment_distance(p: Vector, a: Vector, b: Vector) -> float:
    """点到线段的最短距离（不是到直线的距离）。

    用线段而不是直线很重要：到直线的距离会让离骨骼"延长线"很近、
    但实际离骨骼很远的顶点拿到高权重（例如手部顶点被上臂骨抢走）。
    """
    ab = b - a
    ab_len_sq = ab.length_squared
    if ab_len_sq < 1e-12:
        return (p - a).length
    t = (p - a).dot(ab) / ab_len_sq
    t = max(0.0, min(1.0, t))
    return (p - (a + ab * t)).length


# ============================================================
# 动画定义
# ============================================================
#
# 每个动画是一个函数，接收 BonePoser，为每个关键帧返回一个 pose 字典。
# 关键帧的时间点由动画的时序决定（对攻击来说是 windup / active / recovery）。

def _blend_pose(a: dict, b: dict, t: float) -> dict:
    """在两个姿态之间做线性插值。

    用途：某些动作（例如处决的"深蹲蓄力 → 上挑"）需要在两个关键姿态
    之间插一个中间姿态，用这个函数算出来 —— 直接让 Blender 从 A 插值
    到 B 时，路径可能扫过身体、或者姿态变化过于突兀。

    【限制：只支持方向向量形式的姿态】
    姿态里的值可能是方向向量，也可能是 `tilt(...)` 返回的相对倾斜元组。
    相对倾斜的插值需要各自的 (yaw, pitch) 分量线性插值 ——
    对元组做 Vector() 会直接抛错（"sequence index 0 expected a number,
    found 'str'"）。

    这里对 tilt 做**分量线性插值**：两边都是 tilt 就分别插值 yaw/pitch；
    只有一边是 tilt 就取那一侧（不做混合），因为混用两种表示本来
    就没有良好的数学定义，硬凑出来的结果不可预期。
    """
    t = max(0.0, min(1.0, t))
    out: dict = {}
    keys = set(a.keys()) | set(b.keys())
    for k in keys:
        ea = a.get(k)
        eb = b.get(k)
        if ea is None:
            out[k] = eb
            continue
        if eb is None:
            out[k] = ea
            continue

        # 两边都是相对倾斜 -> 分量插值
        if _is_tilt(ea) and _is_tilt(eb):
            ya = ea[1] if len(ea) > 1 else 0.0
            yb = eb[1] if len(eb) > 1 else 0.0
            pa = ea[2] if len(ea) > 2 else 0.0
            pb = eb[2] if len(eb) > 2 else 0.0
            merged: tuple = (REST, ya + (yb - ya) * t, pa + (pb - pa) * t)
            # 位移偏移取两者之间（只有一个有偏移时取那个）
            oa = ea[3] if len(ea) > 3 else None
            ob = eb[3] if len(eb) > 3 else None
            off = _lerp_offset(oa, ob, t)
            out[k] = merged + (off,) if off is not None else merged
            continue

        # 混用两种表示 -> 取进度过半的那一侧，避免产生不可预期的姿态
        out[k] = ea if t < 0.5 else eb
    return out


def _is_tilt(entry) -> bool:
    return isinstance(entry, tuple) and len(entry) >= 2 and entry[0] == REST


def _lerp_offset(oa, ob, t: float):
    """插值姿态里的位移偏移分量（可能为 None）。"""
    if oa is None and ob is None:
        return None
    if oa is None:
        return ob
    if ob is None:
        return oa
    va = Vector(oa)
    vb = Vector(ob)
    return va.lerp(vb, t)


## ---- 待机姿态：略含胸、呼吸起伏极小、刀垂在身侧 ----
def pose_idle(breathe: float = 0.0) -> dict:
    """待机。

    breathe 0~1 控制呼吸幅度，用于两个关键帧之间的起伏。

    躯干用 `tilt()` 表达（在静止朝向上叠加少量前倾）。
    **不要**给躯干骨骼传 FWD 之类的绝对方向 —— 这些骨骼的
    "静止上方向"是 -Y（朝后），传 FWD 会让参考轴翻转 180 度，
    整个躯干被拧成漏斗状。这个坑真实踩过，见 BonePoser 的说明。
    """
    b = breathe
    return {
        "Hips":       (tilt(0.0, 1.5 + b * 1.5), None, (0.0, 0.0, -0.012 * b)),
        "Spine":      (tilt(0.0, 3.0 + b * 2.0), None),
        "Chest":      (tilt(0.0, 2.0 + b * 1.5), None),
        "Neck":       (tilt(0.0, -2.0), None),
        "Head":       (tilt(0.0, -1.0 + b * 1.0), None),
        # 手臂自然下垂
        "Shoulder.L": (dir3(0.55, 0.10, -0.83), UP),
        "UpperArm.L": (dir3(0.16, 0.08, -0.98), UP),
        "LowerArm.L": (dir3(0.10, 0.22, -0.97), UP),
        "Hand.L":     (dir3(0.06, 0.28, -0.96), UP),
        "Shoulder.R": (dir3(-0.55, 0.10, -0.83), UP),
        "UpperArm.R": (dir3(-0.16, 0.08, -0.98), UP),
        "LowerArm.R": (dir3(-0.10, 0.22, -0.97), UP),
        "Hand.R":     (dir3(-0.06, 0.28, -0.96), UP),
        # 腿：基本竖直，膝盖微屈
        "UpperLeg.L": (dir3(0.02, 0.03, -1.0), FWD),
        "LowerLeg.L": (dir3(0.0, -0.04, -1.0), FWD),
        "Foot.L":     (dir3(0.0, 0.94, -0.34), UP),
        "UpperLeg.R": (dir3(-0.02, -0.03, -1.0), FWD),
        "LowerLeg.R": (dir3(0.0, 0.04, -1.0), FWD),
        "Foot.R":     (dir3(0.0, 0.94, -0.34), UP),
    }


## ---- 战斗准备姿态（中段之构）：双脚前后开立、刀斜举在身前 ----
#
# 这是所有攻击动作的起点与终点。它必须稳定可靠 ——
# 如果它本身就歪，所有动作都会跟着歪。
def pose_guard() -> dict:
    return {
        "Hips":       (tilt(0.0, 2.0), None, (0.0, 0.0, -0.03)),
        "Spine":      (tilt(0.0, 5.0), None),
        "Chest":      (tilt(0.0, 3.0), None),
        "Neck":       (tilt(0.0, -3.0), None),
        "Head":       (tilt(0.0, -2.0), None),
        # 左手扶在刀柄前方
        "Shoulder.L": (dir3(0.50, 0.42, -0.76), UP),
        "UpperArm.L": (dir3(0.30, 0.62, -0.72), UP),
        "LowerArm.L": (dir3(-0.05, 0.88, -0.47), UP),
        "Hand.L":     (dir3(-0.12, 0.94, -0.32), UP),
        # 右手握柄，刀身斜指前上方
        "Shoulder.R": (dir3(-0.50, 0.38, -0.78), UP),
        "UpperArm.R": (dir3(-0.28, 0.50, -0.82), UP),
        "LowerArm.R": (dir3(-0.05, 0.80, -0.60), UP),
        "Hand.R":     (dir3(0.10, 0.90, -0.42), UP),
        # 左脚在前、右脚在后（右脚是发力脚）
        "UpperLeg.L": (dir3(0.04, 0.26, -0.96), FWD),
        "LowerLeg.L": (dir3(0.0, -0.20, -0.98), FWD),
        "Foot.L":     (dir3(0.0, 0.96, -0.28), UP),
        "UpperLeg.R": (dir3(-0.04, -0.24, -0.97), FWD),
        "LowerLeg.R": (dir3(0.0, 0.26, -0.96), FWD),
        "Foot.R":     (dir3(0.0, 0.90, -0.44), UP),
    }


## ---- 挥砍终点姿态生成器 ----
def pose_slash_end(side: float, high: float = 0.0) -> dict:
    """挥砍结束时的姿态。

    参数约定（与 pose_windup 配成一组）：
        side = +1  ->  刀扫到角色**左侧**（+X）
        side = -1  ->  刀扫到角色**右侧**（-X）
        side 接近 0 时刀停在身体正前方（用于正劈/上挑）

    high: 0 = 水平横扫；+1 = 向上挑；-1 = 向下劈
    """
    s = side
    pose = pose_guard()
    # 躯干随转体扭转（用 tilt 的 yaw 分量，保持直立不歪）
    pose["Hips"] = (tilt(10.0 * s, 3.0), None, (0.0, 0.03, -0.03))
    pose["Spine"] = (tilt(18.0 * s, 8.0), None)
    pose["Chest"] = (tilt(24.0 * s, 5.0), None)
    pose["Neck"] = (tilt(-8.0 * s, -2.0), None)
    pose["Head"] = (tilt(-12.0 * s, -1.0), None)

    # 双臂挥到侧前方。high 控制抬手的程度。
    dh = high * 0.55
    pose["Shoulder.L"] = (dir3(0.45 + 0.20 * s, 0.72, -0.40 + dh), UP)
    pose["UpperArm.L"] = (dir3(0.28 + 0.35 * s, 0.80, -0.35 + dh), UP)
    pose["LowerArm.L"] = (dir3(0.20 + 0.30 * s, 0.90, -0.10 + dh * 1.2), UP)
    pose["Hand.L"] = (dir3(0.12 + 0.25 * s, 0.94, -0.02 + dh * 1.3), UP)
    pose["Shoulder.R"] = (dir3(-0.45 + 0.45 * s, 0.70, -0.42 + dh), UP)
    pose["UpperArm.R"] = (dir3(-0.28 + 0.55 * s, 0.78, -0.38 + dh), UP)
    pose["LowerArm.R"] = (dir3(-0.20 + 0.45 * s, 0.88, -0.12 + dh * 1.2), UP)
    pose["Hand.R"] = (dir3(-0.12 + 0.35 * s, 0.92, -0.04 + dh * 1.3), UP)

    # 腿随转体：前脚踏实、后脚蹬伸
    pose["UpperLeg.L"] = (dir3(0.04 + 0.20 * s, 0.32, -0.94), FWD)
    pose["LowerLeg.L"] = (dir3(0.0, -0.24, -0.97), FWD)
    pose["Foot.L"] = (dir3(0.0, 0.98, -0.20), UP)
    pose["UpperLeg.R"] = (dir3(-0.04 + 0.20 * s, -0.10, -0.99), FWD)
    pose["LowerLeg.R"] = (dir3(0.0, 0.14, -0.99), FWD)
    pose["Foot.R"] = (dir3(0.0, 0.86, -0.52), UP)
    return pose


## ---- 举刀蓄势姿态（起手帧的目标姿态）----
def pose_windup(side: float, height: float = 1.0) -> dict:
    """起手：刀被拉到身体**同侧**的后上方。

    参数约定（与 pose_slash_end 配成一组，两处必须一致）：
        side = +1  ->  刀拉到角色**右侧**（-X），准备由右向左横斩
        side = -1  ->  刀拉到角色**左侧**（+X），准备由左向右反手斩

    height: 拉得越高，蓄势越明显

    内部把 side 取反后再代入 x 分量：因为"拉到右侧"意味着 x 分量为负，
    而 side=+1 直觉上应该对应右侧。用取反而不是在每个分量上手写负号，
    是为了后面调参数时不必反复确认符号。
    """
    s = -side
    pose = pose_guard()
    # 躯干向后扭转
    pose["Hips"] = (tilt(-12.0 * s, 1.0), None, (0.0, -0.03, -0.05))
    pose["Spine"] = (tilt(-20.0 * s, 2.0), None)
    pose["Chest"] = (tilt(-26.0 * s, 1.0), None)
    pose["Neck"] = (tilt(12.0 * s, -2.0), None)
    pose["Head"] = (tilt(16.0 * s, -1.0), None)

    h = height
    # 双手举到同侧后方
    pose["Shoulder.L"] = (dir3(0.30 + 0.25 * s, -0.10, 0.10 * h), UP)
    pose["UpperArm.L"] = (dir3(0.10 + 0.55 * s, -0.35, 0.30 * h), UP)
    pose["LowerArm.L"] = (dir3(-0.15 + 0.55 * s, -0.20, 0.55 * h), UP)
    pose["Hand.L"] = (dir3(-0.25 + 0.50 * s, -0.10, 0.68 * h), UP)
    pose["Shoulder.R"] = (dir3(-0.30 + 0.40 * s, -0.15, 0.15 * h), UP)
    pose["UpperArm.R"] = (dir3(-0.15 + 0.70 * s, -0.40, 0.32 * h), UP)
    pose["LowerArm.R"] = (dir3(-0.20 + 0.70 * s, -0.25, 0.58 * h), UP)
    pose["Hand.R"] = (dir3(-0.30 + 0.60 * s, -0.12, 0.72 * h), UP)

    # 重心压在后脚（右脚），前脚虚点
    pose["UpperLeg.L"] = (dir3(0.04, 0.20, -0.98), FWD)
    pose["LowerLeg.L"] = (dir3(0.0, -0.14, -0.99), FWD)
    pose["Foot.L"] = (dir3(0.0, 0.92, -0.40), UP)
    pose["UpperLeg.R"] = (dir3(-0.04, -0.34, -0.94), FWD)
    pose["LowerLeg.R"] = (dir3(0.0, 0.40, -0.92), FWD)
    pose["Foot.R"] = (dir3(0.0, 0.96, -0.28), UP)
    return pose


## ---- 受击姿态 ----
def pose_hit(severity: float) -> dict:
    """受击：上身后仰 + 后退。severity 0~1。"""
    k = severity
    pose = pose_guard()
    # 躯干后仰用负的 pitch
    pose["Hips"] = (tilt(0.0, 2.0 - 16.0 * k), None, (0.0, -0.06 * k, -0.04 * k))
    pose["Spine"] = (tilt(0.0, 5.0 - 26.0 * k), None)
    pose["Chest"] = (tilt(0.0, 3.0 - 30.0 * k), None)
    pose["Neck"] = (tilt(0.0, -3.0 - 12.0 * k), None)
    pose["Head"] = (tilt(0.0, -2.0 - 30.0 * k), None)

    # 手臂被震开，向两侧张开
    pose["Shoulder.L"] = (dir3(0.55 + 0.25 * k, 0.05 - 0.35 * k, -0.83 + 0.1 * k), UP)
    pose["UpperArm.L"] = (dir3(0.16 + 0.55 * k, 0.08 - 0.45 * k, -0.98 + 0.2 * k), UP)
    pose["LowerArm.L"] = (dir3(0.10 + 0.45 * k, 0.22 - 0.55 * k, -0.97 + 0.25 * k), UP)
    pose["Hand.L"] = (dir3(0.06 + 0.35 * k, 0.28 - 0.60 * k, -0.96 + 0.28 * k), UP)
    pose["Shoulder.R"] = (dir3(-0.55 - 0.25 * k, 0.05 - 0.35 * k, -0.83 + 0.1 * k), UP)
    pose["UpperArm.R"] = (dir3(-0.16 - 0.55 * k, 0.08 - 0.45 * k, -0.98 + 0.2 * k), UP)
    pose["LowerArm.R"] = (dir3(-0.10 - 0.45 * k, 0.22 - 0.55 * k, -0.97 + 0.25 * k), UP)
    pose["Hand.R"] = (dir3(-0.06 - 0.35 * k, 0.28 - 0.60 * k, -0.96 + 0.28 * k), UP)

    # 后脚撑住、前脚离地
    pose["UpperLeg.L"] = (dir3(0.05, 0.10 + 0.35 * k, -0.93), FWD)
    pose["LowerLeg.L"] = (dir3(0.0, -0.08 - 0.25 * k, -0.96), FWD)
    pose["UpperLeg.R"] = (dir3(-0.05, -0.24 - 0.45 * k, -0.86), FWD)
    pose["LowerLeg.R"] = (dir3(0.0, 0.26 + 0.55 * k, -0.80), FWD)
    return pose


## ---- 死亡姿态 ----
def pose_death(t: float) -> dict:
    """死亡：身体前倾跪倒。t 0~1。

    用跪倒而不是平躺：跪倒在低多边形下更容易辨认，
    也不需要处理身体与地面的穿插。
    """
    k = t
    pose = pose_guard()
    # 躯干大幅前倾
    pose["Hips"] = (tilt(0.0, 2.0 + 42.0 * k), None, (0.0, -0.05 * k, -0.52 * k))
    pose["Spine"] = (tilt(0.0, 5.0 + 30.0 * k), None)
    pose["Chest"] = (tilt(3.0 * k, 3.0 + 22.0 * k), None)
    pose["Neck"] = (tilt(0.0, -3.0 + 20.0 * k), None)
    pose["Head"] = (tilt(0.0, -2.0 + 25.0 * k), None)

    # 手臂无力地垂下
    for tag, sx in (("L", 1.0), ("R", -1.0)):
        pose["Shoulder." + tag] = (dir3(sx * 0.50, 0.10 - 0.40 * k, -0.80 - 0.2 * k), UP)
        pose["UpperArm." + tag] = (dir3(sx * 0.22, 0.10 - 0.55 * k, -0.95 - 0.2 * k), UP)
        pose["LowerArm." + tag] = (dir3(sx * 0.15, 0.15 - 0.70 * k, -0.90 - 0.25 * k), UP)
        pose["Hand." + tag] = (dir3(sx * 0.10, 0.20 - 0.78 * k, -0.85 - 0.28 * k), UP)

    # 前腿跪地、后腿撑住
    pose["UpperLeg.L"] = (dir3(0.05, 0.26 + 0.55 * k, -0.96 + 0.55 * k), FWD)
    pose["LowerLeg.L"] = (dir3(0.0, -0.20 - 0.75 * k, -0.98 + 0.85 * k), FWD)
    pose["Foot.L"] = (dir3(0.0, 0.90 - 0.60 * k, -0.34 + 0.90 * k), UP)
    pose["UpperLeg.R"] = (dir3(-0.05, -0.24 + 0.20 * k, -0.97 + 0.25 * k), FWD)
    pose["LowerLeg.R"] = (dir3(0.0, 0.26 - 0.50 * k, -0.96 + 0.60 * k), FWD)
    pose["Foot.R"] = (dir3(0.0, 0.90 - 0.30 * k, -0.44 + 0.70 * k), UP)
    return pose


## ---- 翻滚姿态 ----
def pose_roll(t: float) -> dict:
    """闪避翻滚：t 0~1 表示翻滚进度。

    用"低身屈膝冲刺"来表现翻滚，而不是真的让身体翻 360 度 ——
    低多边形角色做完整翻转时四肢会明显穿插。
    配合游戏里 4.5 米的实际位移，读起来就是一记干脆的翻滚。
    """
    # 0.0 起步 -> 0.35 最低点 -> 0.7 起身 -> 1.0 站定
    if t < 0.35:
        k = t / 0.35
    elif t < 0.7:
        k = 1.0 - (t - 0.35) / 0.35 * 0.45
    else:
        k = 0.55 * (1.0 - (t - 0.7) / 0.3)

    pose = pose_guard()
    # 整体压低前倾
    pose["Hips"] = (tilt(0.0, 2.0 + 40.0 * k), None, (0.0, 0.02 * k, -0.45 * k))
    pose["Spine"] = (tilt(0.0, 5.0 + 26.0 * k), None)
    pose["Chest"] = (tilt(0.0, 3.0 + 18.0 * k), None)
    pose["Neck"] = (tilt(0.0, -3.0 - 6.0 * k), None)
    pose["Head"] = (tilt(0.0, -2.0 - 10.0 * k), None)

    # 手臂收紧护住身体
    pose["Shoulder.L"] = (dir3(0.48, 0.42, -0.76), UP)
    pose["UpperArm.L"] = (dir3(0.30, 0.66, -0.68), UP)
    pose["LowerArm.L"] = (dir3(0.10, 0.90, -0.42), UP)
    pose["Hand.L"] = (dir3(0.0, 0.95, -0.30), UP)
    pose["Shoulder.R"] = (dir3(-0.48, 0.38, -0.78), UP)
    pose["UpperArm.R"] = (dir3(-0.28, 0.58, -0.76), UP)
    pose["LowerArm.R"] = (dir3(-0.05, 0.82, -0.56), UP)
    pose["Hand.R"] = (dir3(0.05, 0.88, -0.46), UP)

    # 腿蜷起（膝盖抬高）
    pose["UpperLeg.L"] = (dir3(0.05, 0.26 + 0.55 * k, -0.96 + 0.30 * k), FWD)
    pose["LowerLeg.L"] = (dir3(0.0, -0.20 - 0.70 * k, -0.98 + 0.60 * k), FWD)
    pose["UpperLeg.R"] = (dir3(-0.05, -0.24 + 0.40 * k, -0.97 + 0.22 * k), FWD)
    pose["LowerLeg.R"] = (dir3(0.0, 0.26 - 0.60 * k, -0.96 + 0.52 * k), FWD)
    return pose


## ---- 跑步循环姿态 ----
def pose_run(phase: float) -> dict:
    """跑步循环。phase 0~1，用正弦驱动四肢。

    上半身保持战斗准备姿态（刀在身侧），这样跑动中切到攻击
    不会有突兀的跳变。
    """
    a = phase * math.tau
    swing = math.sin(a)
    swing2 = math.sin(a + math.pi)
    bob = math.cos(a * 2.0)      # 上下起伏是脚步的两倍频

    pose = pose_guard()
    pose["Hips"] = (tilt(0.0, 2.0 + 10.0 * absf(swing)), None,
                    (0.0, 0.0, -0.03 - 0.045 * bob))
    pose["Spine"] = (tilt(0.0, 5.0 + 14.0 * absf(swing)), None)
    pose["Chest"] = (tilt(0.0, 3.0 + 10.0 * absf(swing)), None)
    pose["Neck"] = (tilt(0.0, -3.0 - 8.0 * absf(swing)), None)
    pose["Head"] = (tilt(0.0, -2.0 - 5.0 * absf(swing)), None)

    # 腿：前后交替摆动
    pose["UpperLeg.L"] = (dir3(0.03, 0.26 + swing * 0.62, -0.96 + 0.12 * swing), FWD)
    pose["LowerLeg.L"] = (dir3(0.0, -0.20 - maxf(0.0, -swing) * 0.80, -0.98 + 0.10 * swing), FWD)
    pose["Foot.L"] = (dir3(0.0, 0.96, -0.28 + maxf(0.0, swing) * 0.35), UP)
    pose["UpperLeg.R"] = (dir3(-0.03, -0.24 + swing2 * 0.62, -0.97 + 0.12 * swing2), FWD)
    pose["LowerLeg.R"] = (dir3(0.0, 0.26 - maxf(0.0, -swing2) * 0.80, -0.96 + 0.10 * swing2), FWD)
    pose["Foot.R"] = (dir3(0.0, 0.90, -0.44 + maxf(0.0, swing2) * 0.32), UP)

    # 手臂反相摆动（幅度比平时小，因为握着刀）
    pose["Shoulder.L"] = (dir3(0.50, 0.42 - swing * 0.20, -0.76), UP)
    pose["UpperArm.L"] = (dir3(0.30, 0.62 - swing * 0.32, -0.72), UP)
    pose["LowerArm.L"] = (dir3(-0.05, 0.88 - swing * 0.24, -0.47), UP)
    pose["Hand.L"] = (dir3(-0.12, 0.94 - swing * 0.18, -0.32), UP)
    pose["Shoulder.R"] = (dir3(-0.50, 0.38 - swing2 * 0.18, -0.78), UP)
    pose["UpperArm.R"] = (dir3(-0.28, 0.50 - swing2 * 0.30, -0.82), UP)
    pose["LowerArm.R"] = (dir3(-0.05, 0.80 - swing2 * 0.22, -0.60), UP)
    pose["Hand.R"] = (dir3(0.10, 0.90 - swing2 * 0.16, -0.42), UP)
    return pose


def absf(v: float) -> float:
    """math.fabs 的短别名，让上面的姿态公式保持可读。"""
    return abs(v)


def maxf(a: float, b: float) -> float:
    return a if a > b else b


# ============================================================
# 动画录制
# ============================================================

def _new_action(arm_obj, name: str):
    """为骨架创建一个新 action，并设为当前活动 action。"""
    if arm_obj.animation_data is None:
        arm_obj.animation_data_create()
    action = bpy.data.actions.new(name)
    # use_fake_user：防止在没有用户引用时被 Blender 回收。
    # glTF 导出器只导出"存在且有用户"的 action。
    action.use_fake_user = True

    arm_obj.animation_data.action = action
    # Blender 4.4+ 引入了 action slot。设置活动 slot 才能让
    # keyframe_insert 知道该往哪个 slot 写。低版本没有这个属性，
    # 所以用 try/except 兼容。
    try:
        slot = action.slots.new(id_type='OBJECT', name=arm_obj.name)
        arm_obj.animation_data.action_slot = slot
    except (AttributeError, TypeError):
        pass

    return action


def _key_all_bones(arm_obj, frame: int) -> None:
    """为所有骨骼插入位置 + 旋转关键帧。"""
    for pb in arm_obj.pose.bones:
        pb.keyframe_insert(data_path="location", frame=frame)
        pb.keyframe_insert(data_path="rotation_quaternion", frame=frame)


def _seconds_to_frame(t: float) -> int:
    """把秒换算成帧号。

    第 0 秒对应第 0 帧。这一点很重要：Godot 的 AnimationPlayer
    从 0 秒开始播放，如果动画的第一个关键帧在第 1 帧（= 1/30 秒），
    那么开头 1/30 秒会是"从静止姿态滑向第一帧姿态"的补间，
    表现为每次出招前有一帧的姿态抖动。
    """
    return max(0, int(round(t * FPS)))


def record_animation(arm_obj, poser: BonePoser, name: str, keys: list) -> None:
    """录制一个动画。

    keys 是 [(时间秒, 姿态字典), ...]，必须按时间升序。
    每两个相邻姿态之间由 Blender 自己插值。
    """
    _new_action(arm_obj, name)

    for t, pose in keys:
        frame = _seconds_to_frame(t)
        poser.apply(pose)
        _key_all_bones(arm_obj, frame)

    # 设置插值方式：位置用贝塞尔（平滑），旋转用线性到贝塞尔之间。
    # 攻击动作希望"干脆"，所以统一用 BEZIER 但收紧控制点。
    action = arm_obj.animation_data.action
    for fc in action.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = 'BEZIER'
            kp.handle_left_type = 'AUTO_CLAMPED'
            kp.handle_right_type = 'AUTO_CLAMPED'

    duration = keys[-1][0] if keys else 0.0
    log("      %-22s %5.2f 秒（%3d 帧，%d 个关键姿态）" % (
        name, duration, _seconds_to_frame(duration), len(keys)))


def build_all_animations(arm_obj, poser: BonePoser) -> None:
    """生成全部动画。"""

    # ---------- 待机（循环）----------
    # 一个呼吸周期 2.4 秒。用两帧表现"吸气/呼气"，
    # 中间插值出自然的起伏。
    idle_a = pose_idle(0.0)
    idle_b = pose_idle(1.0)      # breathe=1 就是"呼气"那一帧
    record_animation(arm_obj, poser, "idle", [
        (0.0, idle_a),
        (1.2, idle_b),
        (2.4, idle_a),      # 回到起点，保证循环无缝
    ])

    # ---------- 跑步（循环）----------
    run_keys = []
    for i in range(9):
        phase = i / 8.0
        run_keys.append((phase * 0.86, pose_run(phase)))
    record_animation(arm_obj, poser, "run", run_keys)

    # ---------- 三段轻攻击 ----------
    # 时间点严格取自 ATTACK_TIMINGS，与游戏里的判定窗口对齐：
    #   t=0            起手开始（准备姿态）
    #   t=windup       蓄势到位（判定即将开始）
    #   t=windup+active 挥砍完成（判定结束）
    #   t=total        收招完成（回到准备姿态）
    # side 的语义见 pose_windup / pose_slash_end 的文档：
    #   +1 = 由右向左横斩；-1 = 由左向右反手斩
    # 三段的挥砍方向交替，连招才有"一左一右"的节奏感。
    for idx, (aid, (windup, active, recovery, _dmg), side, high) in enumerate([
        ("katana_light_1", ATTACK_TIMINGS["katana_light_1"], 1.0, 0.10),
        ("katana_light_2", ATTACK_TIMINGS["katana_light_2"], -1.0, -0.10),
        ("katana_light_3", ATTACK_TIMINGS["katana_light_3"], 1.0, 0.85),
    ]):
        total = windup + active + recovery
        guard = pose_guard()
        wind = pose_windup(side, 0.75 + idx * 0.15)
        slash = pose_slash_end(side, high)
        # 收招：从挥砍终点缓慢回到准备姿态
        settle = _blend_pose(slash, guard, 0.75)
        record_animation(arm_obj, poser, aid, [
            (0.0, guard),
            (windup, wind),
            (windup + active, slash),
            (windup + active + recovery * 0.5, settle),
            (total, guard),
        ])

    # ---------- 重击·蓄力斩 ----------
    windup, active, recovery, _ = ATTACK_TIMINGS["katana_heavy"]
    total = windup + active + recovery
    guard = pose_guard()
    heavy_wind = pose_windup(1.0, 1.35)       # 举到右侧高处
    heavy_wind["Hips"] = (tilt(-5.0, 6.0), None, (0.0, -0.06, -0.09))  # 重心下沉
    heavy_slash = pose_slash_end(0.55, -0.85)  # 从上往下劈到身前偏左
    record_animation(arm_obj, poser, "katana_heavy", [
        (0.0, guard),
        (windup * 0.55, _blend_pose(guard, heavy_wind, 0.6)),
        (windup, heavy_wind),
        (windup + active, heavy_slash),
        (windup + active + recovery * 0.45, _blend_pose(heavy_slash, guard, 0.6)),
        (total, guard),
    ])

    # ---------- 居合（满蓄）----------
    # 特点：起手极短（刀已在鞘上蓄满），突进距离长，收招很长。
    windup, active, recovery, _ = ATTACK_TIMINGS["katana_iai"]
    total = windup + active + recovery
    # 居合的"起手姿态"是收刀入鞘的拔刀预备式
    iai_ready = pose_guard()
    iai_ready["UpperArm.R"] = (dir3(-0.30, -0.50, -0.80), UP)
    iai_ready["LowerArm.R"] = (dir3(-0.10, -0.65, -0.76), UP)
    iai_ready["Hand.R"] = (dir3(0.05, -0.72, -0.69), UP)
    iai_ready["UpperArm.L"] = (dir3(0.22, 0.30, -0.93), UP)
    iai_ready["LowerArm.L"] = (dir3(0.05, 0.65, -0.76), UP)
    iai_ready["Hand.L"] = (dir3(0.0, 0.80, -0.60), UP)
    iai_ready["Hips"] = (tilt(0.0, 9.0), None, (0.0, -0.04, -0.10))   # 压低重心

    iai_slash = pose_slash_end(1.0, 0.35)
    # 拔刀瞬间：刀从鞘中横向抽出，手在最前，刀尚未扫到位
    iai_draw = pose_slash_end(0.45, 0.15)
    iai_draw["UpperArm.R"] = (dir3(-0.45, 0.72, -0.52), UP)
    iai_draw["LowerArm.R"] = (dir3(-0.22, 0.95, -0.20), UP)
    iai_draw["Hand.R"] = (dir3(-0.10, 0.98, 0.10), UP)
    record_animation(arm_obj, poser, "katana_iai", [
        (0.0, iai_ready),
        (windup, _blend_pose(iai_ready, iai_draw, 0.45)),
        (windup + active * 0.5, iai_draw),
        (windup + active, iai_slash),
        (windup + active + recovery * 0.55, _blend_pose(iai_slash, guard, 0.65)),
        (total, guard),
    ])

    # ---------- 闪避攻击·突进斩 ----------
    windup, active, recovery, _ = ATTACK_TIMINGS["katana_dodge_attack"]
    total = windup + active + recovery
    dodge_wind = pose_guard()
    # 低身前冲：躯干继续用 tilt（绝对方向会把躯干拧歪）
    dodge_wind["Hips"] = (tilt(0.0, 22.0), None, (0.0, 0.06, -0.16))
    dodge_wind["Spine"] = (tilt(0.0, 20.0), None)
    dodge_wind["Chest"] = (tilt(0.0, 14.0), None)
    record_animation(arm_obj, poser, "katana_dodge_attack", [
        (0.0, pose_guard()),
        (windup, dodge_wind),
        (windup + active, pose_slash_end(1.0, 0.55)),
        (windup + active + recovery * 0.5, _blend_pose(pose_slash_end(1.0, 0.55), pose_guard(), 0.7)),
        (total, pose_guard()),
    ])

    # ---------- 处决·一閃 ----------
    # 起手长、收招长，中间是一记大幅度的上挑斩。
    windup, active, recovery, _ = ATTACK_TIMINGS["katana_execution"]
    total = windup + active + recovery
    exec_wind = pose_windup(1.0, 0.5)
    # 深蹲蓄力 / 上挑时重心上提，都只改 Hips 的位移幅度
    exec_wind["Hips"] = (tilt(-9.0, 12.0), None, (0.0, -0.10, -0.20))
    exec_slash = pose_slash_end(1.0, 1.15)                  # 大幅上挑
    exec_slash["Hips"] = (tilt(9.0, 0.0), None, (0.0, 0.12, 0.02))
    record_animation(arm_obj, poser, "katana_execution", [
        (0.0, pose_guard()),
        (windup * 0.6, _blend_pose(pose_guard(), exec_wind, 0.7)),
        (windup, exec_wind),
        (windup + active, exec_slash),
        (windup + active + recovery * 0.5, _blend_pose(exec_slash, pose_guard(), 0.5)),
        (total, pose_guard()),
    ])

    # ---------- 闪避翻滚 ----------
    roll_keys = []
    steps = 6
    for i in range(steps + 1):
        t = i / float(steps)
        roll_keys.append((t * DODGE_DURATION, pose_roll(t)))
    record_animation(arm_obj, poser, "dodge", roll_keys)

    # ---------- 受击 ----------
    record_animation(arm_obj, poser, "hit_light", [
        (0.0, pose_guard()),
        (HITSTUN_LIGHT * 0.20, pose_hit(0.5)),
        (HITSTUN_LIGHT * 0.60, pose_hit(0.28)),
        (HITSTUN_LIGHT, pose_guard()),
    ])
    record_animation(arm_obj, poser, "hit_heavy", [
        (0.0, pose_guard()),
        (HITSTUN_HEAVY * 0.18, pose_hit(1.0)),
        (HITSTUN_HEAVY * 0.45, pose_hit(0.62)),
        (HITSTUN_HEAVY * 0.78, pose_hit(0.30)),
        (HITSTUN_HEAVY, pose_guard()),
    ])

    # ---------- 架势破除（跪地）----------
    record_animation(arm_obj, poser, "poise_break", [
        (0.0, pose_guard()),
        (0.35, pose_hit(0.8)),
        (0.70, pose_death(0.45)),
        (1.60, pose_death(0.42)),
        (2.10, pose_death(0.30)),
    ])

    # ---------- 死亡 ----------
    death_keys = []
    for i in range(6):
        t = i / 5.0
        death_keys.append((t * 1.5, pose_death(t)))
    # 停留一会儿再结束，让死亡姿态看得清
    death_keys.append((1.5 + 1.0, pose_death(1.0)))
    record_animation(arm_obj, poser, "death", death_keys)


# ============================================================
# 预览渲染
# ============================================================

def setup_preview_scene() -> None:
    """搭一个用于渲染预览的最小场景。"""
    scene = bpy.context.scene
    # 用 Workbench：无头环境下最稳定，不需要 GPU 光线追踪
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.render.resolution_x = 420
    scene.render.resolution_y = 560
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = 'PNG'
    # Workbench 的基本着色
    shading = scene.display.shading
    shading.light = 'STUDIO'
    shading.color_type = 'MATERIAL'
    shading.show_shadows = True
    shading.show_cavity = True
    scene.display.render_aa = 'FXAA'

    # 相机：放在角色右前方，略微俯视
    bpy.ops.object.camera_add(location=(2.6, -3.2, 2.0))
    cam = bpy.context.active_object
    cam.name = "PreviewCam"
    cam.rotation_euler = Euler((math.radians(70.0), 0.0, math.radians(39.0)), 'XYZ')
    scene.camera = cam

    # 环境光
    bpy.ops.object.light_add(type='SUN', location=(3.0, -4.0, 6.0))
    sun = bpy.context.active_object
    sun.data.energy = 4.0
    sun.rotation_euler = Euler((math.radians(52.0), 0.0, math.radians(35.0)), 'XYZ')


def render_previews(arm_obj, only: list = None) -> None:
    """把每个 action 的关键帧渲染成一张横向拼接的图。

    用拼接图而不是逐帧出图：一张图里能看到整个动作的演变，
    比翻十几张图快得多。
    """
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    scene = bpy.context.scene

    actions = []
    for a in bpy.data.actions:
        if only and a.name not in only:
            continue
        actions.append(a)
    actions.sort(key=lambda a: a.name)

    for action in actions:
        arm_obj.animation_data.action = action
        try:
            if len(action.slots) > 0:
                arm_obj.animation_data.action_slot = action.slots[0]
        except (AttributeError, TypeError):
            pass

        fstart, fend = action.frame_range
        fstart = int(fstart)
        fend = int(fend)
        if fend <= fstart:
            continue

        # 取 6 个采样点
        samples = 6
        out_paths = []
        for i in range(samples):
            f = fstart + int((fend - fstart) * i / float(samples - 1))
            scene.frame_set(f)
            path = os.path.join(PREVIEW_DIR, "_tmp_%s_%02d.png" % (action.name, i))
            scene.render.filepath = path
            bpy.ops.render.render(write_still=True)
            out_paths.append(path)

        # 拼成横向长图（用 Blender 的图像 API，避免依赖 PIL）
        _stitch_horizontal(out_paths,
                            os.path.join(PREVIEW_DIR, "%s.png" % action.name))
        for p in out_paths:
            try:
                os.remove(p)
            except OSError:
                pass
        log("    预览：%s.png" % action.name)


def _stitch_horizontal(paths: list, out_path: str) -> None:
    """把多张 PNG 横向拼成一张。只用 Blender 自带的图像 API。"""
    imgs = []
    for p in paths:
        img = bpy.data.images.load(p)
        imgs.append(img)
    if not imgs:
        return
    w, h = imgs[0].size
    total_w = w * len(imgs)
    out = bpy.data.images.new("stitched", width=total_w, height=h, alpha=False)
    buf = [0.0] * (total_w * h * 4)
    for idx, img in enumerate(imgs):
        px = list(img.pixels)     # RGBA，行优先从下到上
        x_off = idx * w
        for y in range(h):
            src_row = y * w * 4
            dst_row = (y * total_w + x_off) * 4
            buf[dst_row:dst_row + w * 4] = px[src_row:src_row + w * 4]
    out.pixels = buf
    out.filepath_raw = out_path
    out.file_format = 'PNG'
    out.save()
    for img in imgs:
        bpy.data.images.remove(img)
    bpy.data.images.remove(out)


# ============================================================
# 导出
# ============================================================

def export_glb() -> None:
    path = os.path.join(MODEL_DIR, OUT_GLB)
    bpy.ops.object.select_all(action='SELECT')

    full = dict(
        filepath=path,
        export_format='GLB',
        use_selection=False,
        export_apply=False,        # 有骨骼时不能应用修改器，否则骨架会被烘焙掉
        export_yup=True,
        export_animations=True,
        export_animation_mode='ACTIONS',
        export_frame_range=False,
        export_bake_animation=False,
        export_skins=True,
        export_def_bones=False,
        export_optimize_animation_size=False,
    )
    try:
        bpy.ops.export_scene.gltf(**full)
    except TypeError as exc:
        log("    [提示] 部分导出参数不被支持（%s），改用精简参数" % exc)
        bpy.ops.export_scene.gltf(
            filepath=path, export_format='GLB',
            export_animations=True, export_skins=True)

    size = os.path.getsize(path) if os.path.exists(path) else 0
    log("    -> %s  (%.1f KB)" % (path, size / 1024.0))


def save_blend() -> None:
    path = os.path.join(BLEND_DIR, OUT_BLEND)
    bpy.ops.wm.save_as_mainfile(filepath=path)
    log("    -> %s  (%.1f KB)" % (path, os.path.getsize(path) / 1024.0))


# ============================================================
# 主流程
# ============================================================

def main() -> None:
    argv = sys.argv
    preview = "--preview" in argv

    log("=" * 62)
    log("骨骼动画角色生成（Blender %s）" % bpy.app.version_string)
    log("=" * 62)

    os.makedirs(BLEND_DIR, exist_ok=True)
    os.makedirs(MODEL_DIR, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS

    try:
        log("[1/5] 建立骨架")
        arm_obj = build_armature()

        log("[2/5] 建立网格")
        body = build_mesh_body()
        blade = build_katana()

        log("[3/5] 蒙皮绑定")
        bind_meshes(arm_obj, body, blade)

        log("[4/5] 录制动画")
        poser = BonePoser(arm_obj)
        build_all_animations(arm_obj, poser)

        if preview:
            log("[预览] 渲染关键帧")
            setup_preview_scene()
            render_previews(arm_obj)

        log("[5/5] 导出")
        export_glb()
        save_blend()

    except Exception as exc:  # noqa: BLE001
        log("[错误] 生成过程中断：%s" % exc)
        import traceback
        traceback.print_exc()
        sys.exit(1)

    log("=" * 62)
    log("完成。")
    log("  动画列表：")
    for a in sorted(bpy.data.actions, key=lambda x: x.name):
        r = a.frame_range
        log("    %-24s %.2f ~ %.2f 秒" % (a.name, r[0] / FPS, r[1] / FPS))
    log("")
    log("下一步：")
    log("  1. godot --headless --editor --quit          （导入 GLB）")
    log("  2. godot --headless res://tools/builder.tscn （重建场景）")
    log("  3. godot --headless res://tests/test_models.tscn （校验）")
    log("=" * 62)


if __name__ == "__main__":
    main()
