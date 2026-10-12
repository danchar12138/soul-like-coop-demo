# -*- coding: utf-8 -*-
"""
低多边形模型生成脚本（Blender 后台模式）。

用法
----
在项目根目录执行：

    blender --background --python tools/blender_assets.py

或指定 Blender 的完整路径（Windows）：

    "C:\\Users\\60459\\Tools\\blender\\blender-4.5.14-windows-x64\\blender.exe" ^
        --background --python tools/blender_assets.py

产物
----
1. 可编辑的 Blender 源文件：  assets/blender/*.blend
2. 供 Godot 使用的导出文件：  assets/models/*.glb

为什么用脚本而不是手动建模
--------------------------
1. 任务书要求"所有需要保留的模型都应尽可能保存可编辑的 Blender 源文件"。
   脚本本身就是最好的"可编辑源文件"—— 改一个数字重跑即可，不依赖
   任何人记住上次在界面里点了什么。
2. 比例与朝向可以统一：所有模型都以米为单位、原点在脚底/中心、
   面向 Blender 的 -Y（导出 GLB 后即为 Godot 的 -Z 前向，
   与本项目 MathUtil 的约定一致）。
3. 命名与材质统一，导入 Godot 后不会出现"角色比例错误、
   武器位置偏移、法线问题"。

模型清单
--------
  player.glb          主角（1.8 m 高，人形，含手部挂点）
  katana.glb          太刀（握持点在原点，刀尖朝 -Y）
  boss.greatsword.glb Boss 灰烬巨兵（3.2 m 高，重甲巨人）
  pillar.glb          可破坏石柱（5 段，与场景中的碰撞体对应）
  wall.glb            可破坏墙体（3x2 砖块）
  arena.props.glb     战场环境结构（地砖、平台、边界石堆）

统一规范
--------
- 单位：米。角色身高 1.8 m，Boss 3.2 m，石柱 4.3 m。
- 原点：角色/道具在脚底或几何中心；武器在握持点。
- **朝向：面向 Blender 的 +Y**（这部分极易搞错，单独说明，见下）。

朝向约定的推导
--------------
Blender 是 Z 轴向上、Y 轴向前（默认"前视图"沿 +Y 看）。
Godot 是 Y 轴向上、**-Z 向前**（见 scripts/core/math_util.gd 的说明）。

glTF 导出器用这个映射做坐标转换：
    Godot.x =  Blender.x
    Godot.y =  Blender.z
    Godot.z = -Blender.y

要让它落在 Godot 的 -Z 上，就必须满足 Godot.z < 0，
即 -Blender.y < 0，也就是 **Blender.y > 0**。

结论：**模型的脸、脚尖、胸前护甲都要朝 +Y**。
如果朝 -Y 放，导出到 Godot 后模型会转 180 度背对镜头 ——
表现为"角色在向后走"、"武器挂在背后"。

- 材质：Principled BSDF，粗糙度 0.85，不使用贴图（纯色低多边形风格）。
- 多边形数：全部采用低面数基本体，总面数 < 3000。

限制说明
--------
本脚本生成的是**静态网格**，不含骨骼与蒙皮动画。
角色动画仍需要人工制作或使用其他工具链。
这一点在 docs/测试记录.md 中已如实记录。
"""

import os
import sys
import math

try:
    import bpy
    import mathutils
except ImportError:
    print("[错误] 本脚本必须在 Blender 的 Python 环境中运行。")
    print("       请使用: blender --background --python tools/blender_assets.py")
    sys.exit(1)


# ============================================================
# 路径
# ============================================================

def _project_root() -> str:
    """从本脚本的位置推断项目根目录（tools/ 的上一级）。"""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(here)


ROOT = _project_root()
BLEND_DIR = os.path.join(ROOT, "assets", "blender")
MODEL_DIR = os.path.join(ROOT, "assets", "models")

MODE_SILENT = os.environ.get("BLENDER_ASSETS_VERBOSE", "0") != "1"


def log(msg: str) -> None:
    print(msg)


def info(msg: str) -> None:
    if not MODE_SILENT:
        print("    " + msg)


# ============================================================
# 基础工具
# ============================================================

def ensure_dirs() -> None:
    for d in (BLEND_DIR, MODEL_DIR):
        os.makedirs(d, exist_ok=True)


def reset_scene() -> None:
    """清空当前场景，回到一个干净的状态。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def make_material(name: str, color, roughness: float = 0.85, metallic: float = 0.0,
                  emission=None, emission_strength: float = 0.0):
    """建立一个 Principled BSDF 材质。color 为 (r, g, b) 的 0~1 浮点。"""
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf is None:
        return mat
    r, g, b = color
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission is not None:
        er, eg, eb = emission
        bsdf.inputs["Emission Color"].default_value = (er, eg, eb, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission_strength
    # 低多边形风格：关闭自动平滑，让面片保持清晰
    mat.use_backface_culling = False
    return mat


def add_box(name: str, size, location, material, rotation=(0.0, 0.0, 0.0)):
    """建立一个长方体。size/location/rotation 均以米/弧度为单位。"""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (size[0], size[1], size[2])
    obj.rotation_euler = rotation
    _assign_material(obj, material)
    _shade_flat(obj)
    return obj


def add_cylinder(name: str, radius: float, depth: float, location,
                 material, vertices: int = 8, rotation=(0.0, 0.0, 0.0),
                 radius_top: float = None):
    """建立低面数圆柱（默认 8 边，符合低多边形风格）。
    radius_top 与 radius 不同时，得到锥台。"""
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices, radius=radius, depth=depth, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.rotation_euler = rotation
    if radius_top is not None and abs(radius_top - radius) > 1e-6:
        # 通过缩放顶面顶点做锥台
        mesh = obj.data
        half = depth * 0.5
        ratio = radius_top / radius if radius > 1e-6 else 1.0
        for v in mesh.vertices:
            if v.co.z > 0:
                v.co.x *= ratio
                v.co.y *= ratio
    _assign_material(obj, material)
    _shade_flat(obj)
    return obj


def add_sphere(name: str, radius: float, location, material,
               segments: int = 8, rings: int = 5):
    """建立低面数球（用于关节/装饰）。"""
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=segments, ring_count=rings, radius=radius, location=location)
    obj = bpy.context.active_object
    obj.name = name
    _assign_material(obj, material)
    _shade_flat(obj)
    return obj


def add_cone(name: str, radius1: float, radius2: float, depth: float,
             location, material, vertices: int = 8, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices, radius1=radius1, radius2=radius2,
        depth=depth, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.rotation_euler = rotation
    _assign_material(obj, material)
    _shade_flat(obj)
    return obj


def _assign_material(obj, material) -> None:
    if obj.data.materials:
        obj.data.materials[0] = material
    else:
        obj.data.materials.append(material)


def _shade_flat(obj) -> None:
    """强制平面着色，保持低多边形的硬边外观。"""
    for poly in obj.data.polygons:
        poly.use_smooth = False


def join_objects(objects, name: str):
    """把多个物体合并成一个，便于作为单个网格导出。"""
    if not objects:
        return None
    bpy.ops.object.select_all(action='DESELECT')
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    merged = bpy.context.active_object
    merged.name = name
    return merged


def add_empty(name: str, location):
    """建立一个空物体，用作 Godot 中的挂点（如手部、武器握持点）。"""
    bpy.ops.object.empty_add(type='PLAIN_AXES', location=location)
    e = bpy.context.active_object
    e.name = name
    e.empty_display_size = 0.1
    return e


def export_glb(filename: str, objects=None) -> None:
    """导出为 GLB。

    关键导出选项：
      export_format='GLB'  —— 单文件二进制，Godot 直接可用
      export_apply=True    —— 应用修改器
      export_yup=True      —— 转成 Y 轴向上（Godot 约定）
      use_selection=True   —— 只导出选中的物体

    注意：不同 Blender 版本的 glTF 导出器参数名会变（例如 4.2 之后
    部分参数被重命名），所以这里用"完整参数先试、失败再退化为最小参数"
    的写法，保证脚本在多个版本上都能跑通。
    """
    path = os.path.join(MODEL_DIR, filename)
    bpy.ops.object.select_all(action='DESELECT')
    use_sel = False
    if objects:
        for o in objects:
            o.select_set(True)
        bpy.context.view_layer.objects.active = objects[0]
        use_sel = True

    full = dict(
        filepath=path,
        export_format='GLB',
        use_selection=use_sel,
        export_apply=True,
        export_yup=True,
    )
    try:
        bpy.ops.export_scene.gltf(**full)
    except TypeError:
        minimal = dict(filepath=path, export_format='GLB', use_selection=use_sel)
        bpy.ops.export_scene.gltf(**minimal)

    size = os.path.getsize(path) if os.path.exists(path) else 0
    log("    -> %s  (%.1f KB)" % (path, size / 1024.0))


def save_blend(filename: str) -> None:
    path = os.path.join(BLEND_DIR, filename)
    bpy.ops.wm.save_as_mainfile(filepath=path)
    size = os.path.getsize(path) if os.path.exists(path) else 0
    log("    -> %s  (%.1f KB)" % (path, size / 1024.0))


def count_tris() -> int:
    """统计当前场景的总三角形数，用于控制模型复杂度。"""
    total = 0
    for obj in bpy.data.objects:
        if obj.type != 'MESH':
            continue
        mesh = obj.data
        for poly in mesh.polygons:
            total += max(1, len(poly.vertices) - 2)
    return total


# ============================================================
# 调色板（与 Godot 场景里的占位色保持一致，替换后视觉连续）
# ============================================================

def srgb(hex_code: str):
    """把 #RRGGBB 转成 Blender 需要的线性 0~1 浮点。

    Blender 的 Base Color 是线性空间。直接除以 255 会让颜色偏亮，
    这里做标准的 sRGB -> 线性转换。
    """
    h = hex_code.lstrip("#")
    out = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255.0
        c = c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
        out.append(c)
    return tuple(out)


PALETTE = {
    # 主角
    "player_body":   srgb("#C7CCDB"),
    "player_limb":   srgb("#ADB2C0"),
    "player_dark":   srgb("#6B7085"),
    "player_head":   srgb("#DBD1C2"),
    "player_cloth":  srgb("#8B3A3A"),

    # 武器
    "steel":         srgb("#E0E4EA"),
    "steel_edge":    srgb("#F5F7FA"),
    "brass":         srgb("#59503A"),
    "leather":       srgb("#38342E"),

    # Boss
    "boss_armor":    srgb("#615D6B"),
    "boss_dark":     srgb("#423F4D"),
    "boss_cloth":    srgb("#7A3E38"),
    "boss_glow":     srgb("#F26A2E"),

    # 地形
    "stone_1":       srgb("#80808A"),
    "stone_2":       srgb("#85858F"),
    "stone_3":       srgb("#8C8C96"),
    "stone_4":       srgb("#91919B"),
    "stone_5":       srgb("#999AA3"),
    "brick_lo":      srgb("#66666D"),
    "brick_hi":      srgb("#74747B"),
    "ground":        srgb("#4D4D52"),
    "cliff":         srgb("#434346"),
}


# ============================================================
# 主角
# ============================================================

def build_player() -> None:
    """主角：1.8 m 高，面向 Blender 的 +Y（导出后 = Godot 的 -Z 前向）。"""
    log("[1/6] 生成主角 player.glb")
    reset_scene()
    m_body = make_material("PlayerBody", PALETTE["player_body"], 0.75)
    m_limb = make_material("PlayerLimb", PALETTE["player_limb"], 0.8)
    m_dark = make_material("PlayerDark", PALETTE["player_dark"], 0.85)
    m_head = make_material("PlayerHead", PALETTE["player_head"], 0.8)
    m_cloth = make_material("PlayerCloth", PALETTE["player_cloth"], 0.9)

    parts = []

    # 躯干：用 8 边柱体做锥台，肩宽腰窄
    parts.append(add_cylinder(
        "Torso", radius=0.20, radius_top=0.26, depth=0.52, vertices=8,
        location=(0.0, 0.0, 1.24), material=m_body))

    # 胸前护甲片（在 +Y 侧，即角色的正面）
    parts.append(add_box(
        "ChestPlate", (0.30, 0.16, 0.20), (0.0, 0.15, 1.34), m_body))

    # 腰带
    parts.append(add_cylinder(
        "Belt", radius=0.215, depth=0.09, vertices=8,
        location=(0.0, 0.0, 0.98), material=m_dark))

    # 战裙（4 片，低多边形风格）
    for i, ang in enumerate((0.0, math.pi * 0.5, math.pi, math.pi * 1.5)):
        dx = math.sin(ang) * 0.16
        dy = math.cos(ang) * 0.16
        parts.append(add_box(
            "Skirt%d" % i, (0.14, 0.10, 0.30),
            (dx, dy, 0.86), m_cloth, rotation=(0.0, 0.0, ang)))

    # 头
    parts.append(add_box("Head", (0.17, 0.18, 0.20), (0.0, 0.0, 1.63), m_head))

    # 四肢
    for side, sx in (("L", -1.0), ("R", 1.0)):
        # 上臂
        parts.append(add_cylinder(
            "UpperArm" + side, radius=0.062, depth=0.30, vertices=6,
            location=(sx * 0.26, 0.0, 1.38), material=m_limb))
        # 前臂
        parts.append(add_cylinder(
            "LowerArm" + side, radius=0.055, depth=0.28, vertices=6,
            location=(sx * 0.26, 0.0, 1.10), material=m_limb))
        # 手
        parts.append(add_box(
            "Hand" + side, (0.075, 0.08, 0.075),
            (sx * 0.26, 0.0, 0.94), m_dark))
        # 大腿
        parts.append(add_box(
            "Thigh" + side, (0.11, 0.12, 0.34),
            (sx * 0.105, 0.0, 0.66), m_dark))
        # 小腿
        parts.append(add_box(
            "Shin" + side, (0.095, 0.11, 0.32),
            (sx * 0.105, 0.0, 0.32), m_dark))
        # 脚（脚尖朝 +Y，即正前方）
        parts.append(add_box(
            "Foot" + side, (0.105, 0.20, 0.075),
            (sx * 0.105, 0.045, 0.04), m_dark))

    body = join_objects(parts, "PlayerBody")

    # 面罩刻意**不合并**进身体，保留为独立的命名节点。
    # 两个用途：
    #   1. Godot 侧的调试工具可以据此找到"角色的正面"
    #   2. tests/test_models.gd 用它来校验朝向是否反了 180 度
    #      （这是一个真实会犯的错误，见 blender_assets.py 顶部的说明）
    visor = add_box("Visor", (0.19, 0.06, 0.05), (0.0, 0.09, 1.66), m_dark)

    # 手部挂点（供 Godot 里挂武器；空物体在 GLB 中导出为节点）
    hand_anchor = add_empty("WeaponSocket", (0.26, 0.0, 0.94))

    log("    三角面数：%d" % count_tris())
    export_glb("player.glb", [body, visor, hand_anchor])
    save_blend("player.blend")


# ============================================================
# 太刀
# ============================================================

def build_katana() -> None:
    """太刀：握持点在原点，刀身沿 Blender 的 +Z 向上，刀尖朝上。

    导出到 Godot 后，把模型挂到手的挂点上，再用 grip_rotation_deg
    调整到自然的握持姿态。
    """
    log("[2/6] 生成太刀 katana.glb")
    reset_scene()

    m_steel = make_material("Steel", PALETTE["steel"], 0.28, metallic=0.75)
    m_edge = make_material("SteelEdge", PALETTE["steel_edge"], 0.18, metallic=0.85)
    m_brass = make_material("Brass", PALETTE["brass"], 0.42, metallic=0.6)
    m_leather = make_material("HandleWrap", PALETTE["leather"], 0.95)

    parts = []

    # 刀柄（原点附近，握持点在这里）
    parts.append(add_box("Grip", (0.030, 0.042, 0.28), (0.0, 0.0, 0.14), m_leather))
    # 柄头
    parts.append(add_box("Pommel", (0.038, 0.050, 0.030), (0.0, 0.0, -0.01), m_brass))
    # 护手（圆盘状，太刀的特征）
    parts.append(add_cylinder(
        "Guard", radius=0.075, depth=0.018, vertices=12,
        location=(0.0, 0.0, 0.29), material=m_brass))

    # 刀身：略微加宽的锥台，带微小弧度（用两段拼接出刀反）
    parts.append(add_box("Blade1", (0.026, 0.062, 0.44), (0.0, 0.004, 0.52), m_steel))
    parts.append(add_box("Blade2", (0.024, 0.058, 0.38), (0.0, -0.020, 0.93), m_steel))
    # 刀尖（楔形收尾）
    parts.append(add_box("Tip", (0.020, 0.040, 0.10), (0.0, -0.048, 1.16), m_steel))

    # 刃口：一条更亮的细长条，突出"锋利"
    parts.append(add_box("Edge1", (0.009, 0.014, 0.44), (-0.015, 0.030, 0.52), m_edge))
    parts.append(add_box("Edge2", (0.009, 0.013, 0.38), (-0.015, 0.007, 0.93), m_edge))

    blade = join_objects(parts, "Katana")

    log("    三角面数：%d" % count_tris())
    export_glb("katana.glb", [blade])
    save_blend("katana.blend")


# ============================================================
# Boss
# ============================================================

def build_boss() -> None:
    """Boss 灰烬巨兵：3.2 m 高。宽肩、短腿、粗臂、小头。

    身体与巨剑导出为**两个独立节点**，便于 Godot 侧把剑挂到
    WeaponPivot 上单独做挥砍位移，也让校验脚本能只量身体的高度。
    """
    log("[3/6] 生成 Boss boss_greatsword.glb")
    reset_scene()

    m_armor = make_material("BossArmor", PALETTE["boss_armor"], 0.7, metallic=0.25)
    m_dark = make_material("BossDark", PALETTE["boss_dark"], 0.78, metallic=0.2)
    m_cloth = make_material("BossCloth", PALETTE["boss_cloth"], 0.92)
    m_glow = make_material("BossGlow", PALETTE["boss_glow"], 0.4,
                           emission=PALETTE["boss_glow"], emission_strength=4.0)
    m_steel = make_material("BossSteel", PALETTE["steel"], 0.3, metallic=0.7)

    parts = []

    # 躯干（主体，很宽）
    parts.append(add_box("Torso", (0.85, 0.52, 0.65), (0.0, 0.0, 2.05), m_armor))
    # 胸甲
    parts.append(add_box("Chest", (0.65, 0.58, 0.30), (0.0, 0.01, 2.55), m_dark))
    # 战裙
    parts.append(add_box("Skirt", (0.70, 0.55, 0.40), (0.0, 0.0, 1.25), m_cloth))

    # 腿（短而粗）
    for side, sx in (("L", -1.0), ("R", 1.0)):
        parts.append(add_box("Thigh" + side, (0.23, 0.25, 0.52),
                             (sx * 0.21, 0.0, 0.55), m_dark))
        parts.append(add_box("Foot" + side, (0.28, 0.42, 0.16),
                             (sx * 0.21, 0.08, 0.08), m_armor))

    # 肩甲（体积很大，是轮廓的关键）
    for side, sx in (("L", -1.0), ("R", 1.0)):
        parts.append(add_box("Shoulder" + side, (0.31, 0.36, 0.26),
                             (sx * 0.50, 0.0, 2.72), m_armor))
        # 肩甲上的尖刺
        parts.append(add_cone("Spike" + side, 0.09, 0.0, 0.22,
                              (sx * 0.50, 0.10, 2.90), m_dark, vertices=6))
        # 上臂
        parts.append(add_cylinder("UpperArm" + side, radius=0.12, depth=0.42,
                                  vertices=6, location=(sx * 0.51, 0.0, 2.38),
                                  material=m_dark))
        # 前臂（带护腕，更粗）
        parts.append(add_cylinder("Forearm" + side, radius=0.135, depth=0.40,
                                  vertices=6, location=(sx * 0.51, 0.0, 1.96),
                                  material=m_armor))
        # 手
        parts.append(add_box("Fist" + side, (0.15, 0.16, 0.15),
                             (sx * 0.51, 0.0, 1.72), m_dark))

    # 颈 + 头（头刻意做小，视觉上强调身体庞大）
    parts.append(add_cylinder("Neck", radius=0.115, depth=0.15, vertices=8,
                              location=(0.0, 0.0, 2.92), material=m_dark))
    parts.append(add_box("Head", (0.23, 0.24, 0.24), (0.0, 0.0, 3.10), m_armor))
    # 头盔顶脊
    parts.append(add_box("Crest", (0.05, 0.22, 0.10), (0.0, 0.0, 3.25), m_dark))

    body = join_objects(parts, "BossGreatsword")

    # 面甲上的发光缝隙（"眼睛"）。同样**不合并**：它是判定 Boss 朝向的
    # 特征点，也是二阶段变红时单独替换材质的对象。
    visor = add_box("Visor", (0.20, 0.06, 0.040), (0.0, 0.12, 3.12), m_glow)

    # 巨剑：单独一个物体，便于 Godot 里挂到 WeaponPivot 上做挥砍
    sword_parts = []
    sword_parts.append(add_box("Blade", (0.075, 0.155, 1.15), (0.0, 0.0, 1.15), m_steel))
    sword_parts.append(add_box("BladeTip", (0.060, 0.11, 0.14), (0.0, 0.0, 1.78), m_steel))
    sword_parts.append(add_box("Fuller", (0.030, 0.035, 1.10), (0.0, 0.0, 1.15), m_dark))
    sword_parts.append(add_box("Crossguard", (0.26, 0.115, 0.065), (0.0, 0.0, 0.02), m_dark))
    sword_parts.append(add_cylinder("Handle", radius=0.055, depth=0.50, vertices=8,
                                    location=(0.0, 0.0, -0.25), material=m_cloth))
    sword = join_objects(sword_parts, "Greatsword")

    log("    三角面数：%d" % count_tris())
    export_glb("boss_greatsword.glb", [body, visor, sword])
    save_blend("boss_greatsword.blend")


# ============================================================
# 可破坏石柱
# ============================================================

def build_pillar() -> None:
    """石柱：5 段，每段是独立物体，与场景里的碰撞体一一对应。

    分段导出而不是整体，是为了让 Godot 侧可以逐段替换：
    打掉第 2 段后，第 2 段的网格消失，其余保持。
    """
    log("[4/6] 生成可破坏石柱 pillar.glb")
    reset_scene()

    keys = ["stone_1", "stone_2", "stone_3", "stone_4", "stone_5"]
    mats = [make_material("Stone%d" % i, PALETTE[k], 0.94) for i, k in enumerate(keys)]

    seg_h = 0.86
    objs = []
    for i in range(5):
        # 上下段半径略有差异，看起来像天然岩石而不是完美圆柱
        r_bottom = 0.62 * (1.18 if i == 0 else 1.06)
        r_top = 0.62 * (0.70 if i == 4 else 0.94)
        seg = add_cylinder(
            "Piece%d" % i, radius=r_bottom, radius_top=r_top,
            depth=seg_h * 0.98, vertices=8,
            location=(0.0, 0.0, seg_h * (i + 0.5)),
            material=mats[i])
        objs.append(seg)

    # 柱顶压顶石
    cap = add_cylinder("Capstone", radius=0.80, radius_top=0.72, depth=0.24,
                       vertices=8, location=(0.0, 0.0, seg_h * 5.0 + 0.10),
                       material=mats[2])
    objs.append(cap)

    log("    三角面数：%d" % count_tris())
    export_glb("pillar.glb", objs)
    save_blend("pillar.blend")


# ============================================================
# 可破坏墙体
# ============================================================

def build_wall() -> None:
    """墙体：3x2 共 6 块砖，每题独立物体便于逐块破坏。"""
    log("[5/6] 生成可破坏墙体 wall.glb")
    reset_scene()

    m_lo = make_material("BrickLow", PALETTE["brick_lo"], 0.92)
    m_hi = make_material("BrickHigh", PALETTE["brick_hi"], 0.92)

    bw, bh, bd = 0.88, 0.62, 0.44
    objs = []
    for cy in range(2):
        for cx in range(3):
            idx = cy * 3 + cx
            brick = add_box(
                "Piece%d" % idx,
                (bw * 0.96, bd, bh * 0.96),          # 注意：Blender 里 Y 是深度
                ((cx - 1) * bw, 0.0, bh * 0.5 + cy * bh),
                m_lo if cy == 0 else m_hi)
            objs.append(brick)

    log("    三角面数：%d" % count_tris())
    export_glb("wall.glb", objs)
    save_blend("wall.blend")


# ============================================================
# 战场环境
# ============================================================

def build_arena_props() -> None:
    """战场环境：环形地砖、可跳上的平台、边界石堆、检查点标记。"""
    log("[6/6] 生成战场环境 arena_props.glb")
    reset_scene()

    m_ground = make_material("Ground", PALETTE["ground"], 0.96)
    m_cliff = make_material("Cliff", PALETTE["cliff"], 0.95)
    m_stone = make_material("PropStone", PALETTE["stone_3"], 0.94)

    objs = []

    # 中央战斗平台（略高，形成"竞技场"的边界感）
    objs.append(add_cylinder("CombatPlatform", radius=16.0, depth=0.30,
                             vertices=12, location=(0.0, 0.0, -0.15),
                             material=m_ground))

    # 环形散布的岩石平台（提供制高点与遮挡）
    ring = [
        (22.0, 0.0, 1.6, 2.2),
        (22.0, math.pi * 0.33, 2.4, 2.0),
        (22.0, math.pi * 0.66, 1.2, 3.2),
        (22.0, math.pi, 2.0, 2.6),
        (22.0, math.pi * 1.33, 1.4, 2.0),
        (22.0, math.pi * 1.66, 2.6, 2.8),
    ]
    for i, (dist, ang, height, width) in enumerate(ring):
        x = math.cos(ang) * dist
        y = math.sin(ang) * dist
        objs.append(add_box("Rock%d" % i, (width, width, height),
                            (x, y, height * 0.5), m_cliff,
                            rotation=(0.0, 0.0, ang)))

    # 边界石堆（视觉上围出战场边界）
    for i in range(8):
        ang = i / 8.0 * math.tau
        x = math.cos(ang) * 29.0
        y = math.sin(ang) * 29.0
        h = 3.0
        objs.append(add_box("Boundary%d" % i, (2.2, 2.2, h),
                            (x, y, h * 0.5), m_cliff,
                            rotation=(0.0, 0.0, ang)))

    # 检查点石碑
    objs.append(add_cylinder("CheckpointBase", radius=0.45, depth=0.22,
                             vertices=8, location=(0.0, 9.0, 0.11),
                             material=m_stone))
    objs.append(add_cylinder("CheckpointStone", radius=0.18, radius_top=0.12,
                             depth=0.90, vertices=6,
                             location=(0.0, 9.0, 0.62), material=m_stone))

    log("    三角面数：%d" % count_tris())
    export_glb("arena_props.glb", objs)
    save_blend("arena_props.blend")


# ============================================================
# 主流程
# ============================================================

def main() -> None:
    log("=" * 60)
    log("低多边形模型生成（Blender %s）" % bpy.app.version_string)
    log("=" * 60)

    if not os.path.isdir(BLEND_DIR):
        ensure_dirs()

    try:
        build_player()
        build_katana()
        build_boss()
        build_pillar()
        build_wall()
        build_arena_props()
    except Exception as exc:  # noqa: BLE001
        log("[错误] 生成过程中断：%s" % exc)
        import traceback
        traceback.print_exc()
        sys.exit(1)

    log("=" * 60)
    log("全部完成。")
    log("  Blender 源文件：assets/blender/")
    log("  Godot 导入资源：assets/models/")
    log("")
    log("下一步（在 Godot 中替换占位模型）：")
    log("  1. 打开 scenes/player/player.tscn")
    log("  2. 删除 Model 节点下的几何体，替换成 player.glb 的实例")
    log("  3. 保留 Hitbox / Hurtbox / Health / StateMachine 等组件节点不动")
    log("  4. 检查 CollisionShape3D 的尺寸是否仍然匹配，必要时调整")
    log("  5. 运行 tests/test_runner.tscn 确认攻击范围没有因为换模型而失效")
    log("=" * 60)


if __name__ == "__main__":
    main()
