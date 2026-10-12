# 模型资源（GLB）

本目录的 `.glb` 文件由 `tools/blender_assets.py` 生成，
在 Godot 中由 `tools/build_scenes.gd` 引用。

| 文件 | 对应对象 | 三角面 | 说明 |
|------|----------|--------|------|
| `player.glb` | 主角 | 316 | 1.73 m 高，含 `WeaponSocket` 手部挂点与独立的 `Visor` 面罩节点 |
| `katana.glb` | 太刀 | 128 | 握持点在原点，刀身沿 +Y 向上 |
| `boss_greatsword.glb` | Boss + 巨剑 | 372 | 3.30 m 高，身体与巨剑是两个独立节点 |
| `pillar.glb` | 可破坏石柱 | 168 | 5 段独立（`Piece0`~`Piece4`）+ 压顶石 |
| `wall.glb` | 可破坏墙体 | 72 | 6 块独立砖（`Piece0`~`Piece5`） |
| `arena_props.glb` | 战场环境 | 260 | 圆形平台、环形岩石、边界石堆、检查点石碑 |

## 重新生成

```bash
blender --background --python tools/blender_assets.py
```

会同时刷新 `assets/blender/*.blend`（可编辑源文件）与本目录的 `.glb`。

## 生成后必须做的事

1. **更新场景**：`godot --headless res://tools/builder.tscn`
   —— 场景里的节点引用需要重新写入。
2. **校验比例与朝向**：`godot --headless res://tests/test_models.tscn`
3. **确认攻击范围没失效**：`godot --headless res://tests/test_runner.tscn`
   —— 换了模型尺寸后，判定盒的位置可能需要跟着调。

## 两个必须注意的约定

### 朝向

模型要面向 **Blender 的 +Y**。

推导：glTF 导出器做 `Godot.z = -Blender.y` 的转换，
要让正面落在 Godot 的 -Z（Godot 的前向），
就必须让 `Blender.y > 0`。

搞反的症状：角色背对镜头、武器挂在背后。
`test_models.gd` 会通过检查 `Visor` 节点的 Z 坐标是否为负来抓这个问题。

### 原点与比例

单位是米。角色原点在**脚底**，Boss 3.2 m 高，石柱 4.3 m 高。
换模型后碰撞体尺寸需要重新核对
（`tools/build_scenes.gd` 里每个角色的 `CollisionShape3D` 是单独定义的，
模型尺寸变化不会自动同步）。

## 场景生成脚本的占位回退

`tools/build_scenes.gd` 按"GLB 存在就用 GLB、不存在就用几何体占位"工作。
所以即使没跑过 Blender 脚本，项目也能构建出可运行的版本。
这对在新环境上手很有用，也意味着**模型缺失不会导致构建失败**，
只会静默回退 —— 构建日志里会打印用的是哪一种。

## 已知限制

**这些是静态网格，不含骨骼与蒙皮动画。**
角色动画（挥砍、受击、闪避、死亡）仍需要人工制作。
当前游戏里角色的动作表现由代码驱动（姿态旋转 + 硬直倾斜），
不是骨骼动画。这一点在 `docs/测试记录.md` 的 K-01 里有详细说明。
