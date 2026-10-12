# 生成脚本

本目录的脚本负责**产出**项目里所有自动生成的文件。
不要手写这些产物（原因见 `docs/技术决策.md` TD-002）。

## 五个脚本

| 脚本 | 产出 | 何时需要重跑 |
|------|------|--------------|
| `generate_weapons.gd` | `resources/weapons/*.tres`（8 个） | 改过攻击数值（时序、伤害、判定框）之后 |
| `blender_assets.py` | `assets/blender/*.blend` + `assets/models/*.glb` | 改过模型之后 |
| `blender_rig.py` | 骨骼与蒙皮 | 改过骨架之后 |
| `build_scenes.gd` | `scenes/**/*.tscn`（7 个） | 改过节点结构、碰撞体、地形布局之后 |
| `generate_audio.py` | `assets/audio/*.wav`（14 个音效 + 1 个氛围） | 改过音效合成参数之后 |
| `generate_audio_buses.gd` | `default_bus_layout.tres` | 改过音频总线/效果器之后 |

后两个是**唯一用 Python 的工具**：音频合成用 Python 标准库比用 GDScript
写 DSP 更短更清楚，且不需要 Autoload 环境（可以用 `-I` 直接跑）。

```bash
# 生成音效（约 1 秒，无需 Godot）
python -I tools/generate_audio.py

# 生成音频总线布局（需要 Godot，用 --script 即可，不依赖 Autoload）
godot --headless --script tools/generate_audio_buses.gd

# 改了 WAV 内容后必须让 Godot 重新导入，否则游戏读的是旧缓存
godot --headless --editor --quit
```


## 执行顺序（有依赖）

```bash
cd <项目根目录>

# 1. 武器数据（场景会引用它）
godot --headless --script tools/generate_weapons.gd

# 2. 模型（场景会引用它；需要 Blender）
blender --background --python tools/blender_assets.py

# 3. 场景（依赖上面两个的产物）
godot --headless res://tools/builder.tscn

# 4. 验证
godot --headless res://tests/test_models.tscn
godot --headless res://tests/test_runner.tscn
```

## 两个容易踩的坑

### 1. `build_scenes.gd` 必须用**场景模式**运行，不能用 `--script`

```bash
# ✓ 正确
godot --headless res://tools/builder.tscn

# ✗ 错误 —— 会报 "Identifier not found: GameConfig"
godot --headless --script tools/build_scenes.gd
```

原因：构建过程要 `load()` 各种脚本，而这些脚本引用了
`GameConfig` / `EventBus` / `GameState` 等 Autoload 单例。
`--script` 模式下引擎**不初始化 Autoload**，编译器找不到这些全局标识符。

`generate_weapons.gd` 则可以用 `--script`，因为它只构造纯数据资源，
不需要访问任何单例。

### 2. `PackedScene.pack()` 只打包 owner 指向根节点的子节点

代码里 `add_child()` **不会**自动设置 `owner`（编辑器拖拽才会）。
不补这一步，生成的 `.tscn` 里就只有根节点一个孤零零的空壳，
运行时找不到 `Hitbox` / `Health` / `AttackController` 等组件。

`build_scenes.gd` 的 `_pack()` 会先调用 `_set_owner_recursive()` 补上。

## 场景生成脚本的占位回退

`build_scenes.gd` 按"**GLB 存在就用 GLB、不存在就用几何体占位**"工作。

好处：
- 没跑过 Blender 的机器也能构建出**可运行**的项目
- 跑过之后重新构建，模型自动替换，不用改任何代码

构建日志会明确打印用的是哪一种：

```
      主体：使用 player.glb（316 三角面）
      武器：使用 katana.glb（128 三角面）
      Boss 模型：使用 boss_greatsword.glb（372 三角面）
      石柱：使用 pillar.glb（168 三角面）
```

如果日志里写的是"使用几何体占位"，说明对应的 `.glb` 不存在。
