# we-layerd-nix

[we-layerd](https://github.com/Aromatic05/we-layerd) 的 Nix Flake 打包 —— Wayland 上的 Wallpaper Engine 原生运行时（守护进程 + GUI）。

本 flake 是上游 **0.2.8** 的**干净重打包**，重点在于**GPU 安全的 RPATH 隔离**与**厂商中立适配**：A 卡（radv）、i 卡（anv）、N 卡（闭源 / nouveau）复用同一份产物，运行时自动派发到宿主显卡驱动。

## 版本钉选（与上游 `package/` 脚本一致）

| 组件 | 版本 / 提交 |
|------|------------|
| we-layerd | `0.2.8` @ `ff118c55`（tag `v0.2.8`） |
| wallpaper-engine-renderer | `89dfcd86`（带全部子模块：Eigen / glslang / SPIRV-Reflect / …） |
| CEF | `144.0.30+g9e70dde` / Chromium `144.0.7559.257`（Spotify CDN minimal） |
| DXC | `1.9.2602.24`（微软官方 Linux 包） |
| 平台 | `x86_64-linux` 唯一（we-cef-helper 含 x86_64 汇编跳板，CEF minimal 无 aarch64） |

## 特性 / 设计

- **厂商中立的 GPU 适配**：渲染器 `.so` 链接 nix `vulkan-loader`（dispatch loader）+ `libglvnd` + `libdrm`，运行时通过宿主 `/run/opengl-driver/share/vulkan/icd.d/` 自动发现 ICD——A 卡 → `radeon_icd`、i 卡 → `intel_icd`、N 卡 → `nvidia_icd`，零配置。
- **RPATH 隔离，杜绝串台**：
  - 渲染器 `libwallpaper-engine-renderer.so` 的 RUNPATH **剥掉** `$out/lib/cef`，改为追加 nix `vulkan-loader/lib`，保证 scene/video 壁纸**走宿主真实 GPU**，而非 CEF 自带的 SwiftShader 软件 Vulkan。
  - CEF 自带的 `libEGL/libGLESv2/libvk_swiftshader/libvulkan.so.1/libcef.so` 首位 RUNPATH 置为 `$ORIGIN`，让 web 壁纸的离屏渲染走 CEF 私有 SwiftShader，与宿主图形栈隔离。
  - 渲染器**不直接链接** `libcef.so`（通过 `we-cef-helper` 子进程 `dlopen`），故其 RPATH 不含 CEF，天然 GPU 安全。
- **纯构建**：`allowUnfree` 内置编译进 nixpkgs 实例，`nix build github:yigexuanmu/we-layerd-nix` 即可，**无需 `--impure` 或 `NIXPKGS_ALLOW_UNFREE`**。
- **完整安装产物**：见下方「安装内容」。
- **we-gui 系统托盘**：`tray-icon → libappindicator-sys` 运行时 `dlopen libayatana-appindicator3.so.1`（非 `DT_NEEDED`），通过 wrapper 的 `LD_LIBRARY_PATH` 注入，strace 验证 dlopen 成功。

## 安装内容

一个 `we-layerd` derivation，输出布局：

```
$out/bin/{we-layerd,we-gui}              # 两个二进制，含 GIO/GStreamer/托盘 env 包装
$out/lib/libwallpaper-engine-renderer.so # C++ 渲染器
$out/lib/we-cef-helper                    # CEF 子进程
$out/lib/cef/                             # CEF 私有运行时：libcef.so + SwiftShader + 220 个 locale pak + Resources
$out/lib/we-layerd/dxc/{libdxcompiler,libdxil}.so  # DXC 着色器编译器
$out/share/applications/we-gui.desktop
$out/share/icons/hicolor/scalable/apps/we-gui.svg
$out/share/gnome-shell/extensions/we-layerd@aromatic/  # GNOME 扩展
$out/share/we-layerd/config.default.toml  # 示例配置（DMA-BUF 失败时的备选，不自动加载）
$out/share/doc/we-layerd/third-party/     # CEF / DXC 许可证
```

## 系统前置

- Nix（flake 已启用）。
- **Wayland 合成器**（wlroots 系 `zwlr_layer_shell_v1`、或 GNOME + 上述扩展）。
- **`hardware.graphics` / Vulkan 驱动**：宿主必须配置好 GPU 驱动，产生 `/run/opengl-driver/share/vulkan/icd.d/`（NixOS 默认行为）。这是任何 Vulkan 程序运行的前提，flak 不重复打包 Mesa。
- 音频服务：PipeWire / PulseAudio（仅在需要音频响应型壁纸时）。

## 安装

### 直接试运行

```bash
nix run github:yigexuanmu/we-layerd-nix#we-layerd -- doctor
nix run github:yigexuanmu/we-layerd-nix --                  # 直接开 GUI
```

### 作为 flake 输入引入

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    we-layerd-nix.url = "github:yigexuanmu/we-layerd-nix";
  };

  outputs = { self, nixpkgs, we-layerd-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          environment.systemPackages = [
            we-layerd-nix.packages.x86_64-linux.default
          ];
        })
      ];
    };
  };
}
```

Home Manager 同理：把 `we-layerd-nix.packages.x86_64-linux.default` 放进 `home.packages`。

### 从源码克隆构建

```bash
git clone https://github.com/yigexuanmu/we-layerd-nix
cd we-layerd-nix
nix build .#we-layerd          # 纯构建，缓存命中秒回
nix build .#we-layerd --out-link result
./result/bin/we-layerd doctor  # 打印环境诊断
```

## 配置

最小配置（默认位置 `~/.config/we-layerd/config.toml`）：

```toml
[renderer]
# 留空 → 守护进程自动按 <bin_dir>/../lib/libwallpaper-engine-renderer.so 查找（本 flake 已按此布局安装）。
library_path = ""
source       = "/path/to/Steam/steamapps/workshop/content/431960/<wallpaper-id>"
assets_path  = "/path/to/Steam/steamapps/common/wallpaper_engine/assets"
cache_path   = "~/.cache/we-layerd/renderer"
```

关键字段：

| 字段 | 说明 |
|------|------|
| `renderer.library_path` | 留空 `""` 启用自动查找（推荐） |
| `renderer.source` | Steam 创意工坊壁纸目录 |
| `renderer.assets_path` | Wallpaper Engine 资源（assets）目录 |
| `renderer.cache_path` | 渲染缓存目录 |
| `renderer.prefer_dmabuf` | 优先走 DMA-BUF 零拷贝上屏，上游默认 `true` |
| `renderer.allow_shm_fallback` | DMA-BUF 不可用时退回 SHM，上游默认 `true` |

### DMA-BUF 失败时的备选配置

若上屏报 `create_immed failed` 一类错误，可改用随包安装的备选配置——它把
`prefer_dmabuf` 关掉、强制走 SHM 共享内存路径：

```bash
nix build .#we-layerd --out-link result
cp result/share/we-layerd/config.default.toml ~/.config/we-layerd/config.toml
```

（已通过 NixOS / Home Manager 安装的，把 `result` 换成该包的 store 路径，即
`$(dirname "$(readlink -f "$(command -v we-gui)")")/../share/we-layerd/config.default.toml`。）

注意这是**绕过**而非修复：关掉 DMA-BUF 会失去零拷贝上屏路径（scene / video 壁纸的正常通路）。
上游 `docs/TROUBLESHOOTING.md` 的建议相反——**保持 `prefer_dmabuf = true`**，让默认就开启的
`allow_shm_fallback = true` 在拿不到 DMA-BUF 时自动回落。只有在确实撞上上述报错时才用备选配置。

完整配置模型见上游文档：[CONFIGURATION.md](https://github.com/Aromatic05/we-layerd/blob/main/docs/CONFIGURATION.md)。

## 使用

```bash
we-gui                                   # 图形界面（浏览创意工坊、生成配置）
we-layerd run --config ~/.config/we-layerd/config.toml   # 直接跑守护进程
we-layerd doctor                         # 环境与渲染器诊断
we-layerd ctl <command>                 # 向运行中的守护进程下发控制命令
```

## GPU 适配（A 卡 / i 卡 / N 卡）

渲染器统一通过 **nix `vulkan-loader`（dispatch loader）** 派发，本 flake 不打包任何私有 ICD：

```
libwallpaper-engine-renderer.so
  └─ vkCreateInstance → libvulkan.so.1  (vulkan-loader)
       └─ 默认扫 /run/opengl-driver/share/vulkan/icd.d/   ← NixOS hardware.graphics 挂载，厂商中立
            ├─ AMD  机器 → radeon_icd.x86_64.json  → libvulkan_radeon.so  (Mesa radv)
            ├─ Intel 机器 → intel_icd.x86_64.json   → libvulkan_intel.so   (Mesa anv)
            └─ NVIDIA 机器 → nvidia_icd.json         (闭源) / nouveau_icd
```

GL / GLES / EGL 经 nix `libglvnd` 派发到宿主 Mesa（radeonsi / iris / …）。因此**同一份产物在三类显卡上都能上屏**，无需为不同厂商构建不同包。

> NVIDIA Optimus 双卡笔记本适用上游内置逻辑：daemon 检测到 `__NV_PRIME_RENDER_OFFLOAD` / `VK_LAYER_NV_optimus` 时会强制 SHM fallback，避免 prime-render-offload 下的兼容问题。这一分支是 NVIDIA 专属，A 卡 / i 卡用户不进入。

## NVIDIA 显卡已知限制

> ⚠️ 下文描述的是**上游 CEF 渲染器**的固有行为，**所有**打包都受影响，非本 flake 独有。

**上游 CEF 的 OSR 共享纹理**（web 壁纸的 DMA-BUF 导出路径）在 NVIDIA GBM 后端上无法初始化 SkSurface——Chromium 把 `SCANOUT_CPU_READ_WRITE` 映射为 `GBM_BO_USE_LINEAR|SCANOUT|TEXTURING`，NVIDIA 不支持，CEF 144 / main 分支均未修复（参考 CEF issue #3953）。因此 **web 类壁纸在 NVIDIA 上可能黑屏/失败**；scene / video 壁纸走 DMA-BUF 硬件路径**不受影响**。

可用上游提供的环境开关缓解（本 flake 不额外补丁，直接暴露上游原生开关）：

```bash
# 关闭 CEF 的 GPU 合成，强制走 CPU 路径渲染 web 壁纸
export WE_CEF_EXTRA_SWITCHES="--disable-gpu-compositing"
we-gui
```

也可在 `config.toml` 调低 `renderer.fps`（如 30）。

> 注：上游没有 `WE_WEB_FORCE_SOFTWARE_PAINT` 开关；该环境变量是**旧版 flake** 的自定义补丁，本干净打包**未包含**。

## 关键环境变量（上游原生）

| 变量 | 作用 |
|------|------|
| `WE_LAYERD_RENDERER_LIBRARY_PATH` | 覆盖渲染器 `.so` 查找，默认 `$bin/../lib/libwallpaper-engine-renderer.so` |
| `WE_CEF_EXTRA_SWITCHES` | 给 `we-cef-helper` 追加 Chromium 命令行开关（如 `--disable-gpu-compositing`） |
| `WE_CEF_RESOURCES_DIR` / `WE_CEF_LOCALES_DIR` / `WE_CEF_HELPER_PATH` / `WE_CEF_CACHE_DIR` | 覆盖 CEF 资源 / locales / 子进程路径 / 缓存目录（本 flake 已默认装好，一般无需设） |
| `WE_LAYERD_BACKEND` | 强制后端（`layer_shell` / …） |
| `GST_PLUGIN_SYSTEM_PATH_1_0` | GStreamer 插件路径（本 flake wrapper 已前置好全插件） |

完整的内部协议型 `WE_FRAME_KIND_*` / `WE_INPUT_*` 等是 we-layerd 与渲染器间的私有 ABI，无需用户关心。

## 与旧版 flake 的差异

旧版（同仓库已删的历史实现）通过自定义补丁做了两件本 flake **未做**的事：

1. **PipeWire 系统音频采集补丁**——让 we-layerd 抓取系统输出做音频响应壁纸。上游 we-layerd 0.2.7 无此能力。本 flake 保持上游原样，**音频响应壁纸随上游行为**（上游的音频通路由渲染器自身处理）。
2. **NVIDIA `WE_WEB_FORCE_SOFTWARE_PAINT` 软件绘制开关**——上游无此开关，是旧 flake 的自定义补丁。本 flake 改用上游原生的 `WE_CEF_EXTRA_SWITCHES="--disable-gpu-compositing"` 作为 NVIDIA web 壁纸的官方缓解路径（见上）。

本 flake 的取向是：**上游原样 + GPU 安全打包**——把工程重心放在确保渲染器走宿主 GPU、与 CEF 的 SwiftShader 隔离，而不是给上游打行为补丁。若需要音频采集 / 软件绘制开关等增强，可 fork 叠加补丁。

## 许可

- we-layerd / wallpaper-engine-renderer 源码未发布开源 license → 包 `meta.license` 标记为 `unfree`（故构建需 `allowUnfree`，本 flake 已内置启用）。
- 第三方组件许可证随包安装到 `$out/share/doc/we-layerd/third-party/`：`CEF-LICENSE.txt`、`DXC-LICENSE-LLVM.txt`、`DXC-LICENSE-MS.txt`。
