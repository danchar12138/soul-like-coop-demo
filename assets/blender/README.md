# Blender 源文件

本目录存放可编辑的 Blender 源文件（`.blend`）。

## 为什么这里有 .gdignore

Godot 会尝试用内置的 Blender 导入器处理 `.blend` 文件，而这需要
在编辑器设置里配置 Blender 可执行文件路径。在无头（`--headless`）
环境下无法配置，会导致导入报错：

```
ERROR: Blender path is invalid or not set, check your Editor Settings.
```

放一个 `.gdignore` 后，Godot 完全跳过本目录。
**游戏实际使用的是 `assets/models/` 下的 GLB**，`.blend` 只是源文件。

## 生成方式

```bash
blender --background --python tools/blender_assets.py
```

这会同时重新生成 `assets/blender/*.blend` 和 `assets/models/*.glb`。

## 文件清单

| 文件 | 对应游戏对象 | 三角面数 |
|------|--------------|----------|
| `player.blend` | 主角（1.8 m） | 316 |
| `katana.blend` | 太刀 | 128 |
| `boss_greatsword.blend` | Boss 灰烬巨兵（3.2 m） | 372 |
| `pillar.blend` | 可破坏石柱（5 段） | 168 |
| `wall.blend` | 可破坏墙体（6 块） | 72 |
| `arena_props.blend` | 战场环境 | — |

## 已确认的限制

**这些是静态网格，不含骨骼与蒙皮动画。**
角色动画（挥砍、受击、闪避、死亡）仍需要人工制作。
当前游戏里角色的动作表现由代码驱动（姿态旋转 + 硬直倾斜），
不是骨骼动画。这一点在 `docs/测试记录.md` 里有如实记录。
