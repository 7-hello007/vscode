# HiSH IDE 精炼项目计划书

## 一、项目总目标

基于 [HiSH](https://github.com/harmoninux/HiSH?utm_source=chatgpt.com) 现有的 Linux/QEMU/终端能力，在**尽可能不修改 HiSH 核心代码**的前提下，构建一个适用于 HarmonyOS PC/平板设备的轻量级代码开发环境。

最终形成完整开发闭环：

**文件管理 → 代码编辑 → 保存 → 终端运行 → AI 辅助**

整体界面采用三栏结构：

```text
┌──────────────┬─────────────────────────┬──────────────┐
│              │      Code Editor        │              │
│  File Tree   ├─────────────────────────┤      AI      │
│              │       Terminal          │              │
└──────────────┴─────────────────────────┴──────────────┘
```

顶部提供 `File / Edit / View / Run / Terminal / Help` 等菜单，插件统一通过 `File → Plugins` 管理，不设置 VS Code 式左侧 Activity Bar。

---

# 二、项目核心思想

项目的核心不是**重新开发一个 VS Code**，也不是**把 HiSH 大规模改造成编辑器**，而是：

> **以 HiSH 作为 Linux Runtime 和 Terminal，在其上增加轻量 IDE Workbench。**

整体遵循三个原则。

**第一，复用而不是重写。**
保留 HiSH 已有 QEMU、Linux VM、QemuAgent、WebTerminal、xterm.js、虚拟机管理等能力，新功能尽量通过独立 `ide/` 模块实现。

**第二，模块解耦。**
File Tree、Editor、Terminal、AI、Plugin 相互独立：

```text
IDE Workbench
│
├── File System
├── Editor
├── Terminal
├── Plugin
└── AI
```

任何一个模块升级都不应该要求修改其他核心模块。

**第三，先完成 IDE，再增加智能能力。**
第一目标是让编辑器真正能够完成开发工作，AI 最后接入，避免 AI 功能影响基础 IDE 的稳定性。

---

# 三、项目阶段

项目划分为 **6 个阶段**。

| 阶段    | 目标               | 核心思路                                                                                              |
| ------- | ------------------ | ----------------------------------------------------------------------------------------------------- |
| Phase 1 | IDE 基础框架       | 将 HiSH 原单终端界面扩展为三栏 Workbench，建立 File Tree、Editor、Terminal、AI 占位区域               |
| Phase 2 | 文件系统           | 利用现有 QemuAgent 与 Linux VM 通信，实现目录读取、新建、删除、重命名、文件读取和保存                 |
| Phase 3 | 代码编辑器         | 通过 ArkWeb 集成 Monaco Editor 或兼容方案，实现语法高亮、行号、多 Tab、搜索、快捷键和保存             |
| Phase 4 | Terminal 与运行    | 原样复用 HiSH WebTerminal，并建立 Editor → Linux → Terminal 的运行流程，实现当前文件运行            |
| Phase 5 | IDE 完善与插件框架 | 完善顶部菜单、状态栏、快捷键、面板调整和 Plugin 管理接口，为 Git、语言工具等扩展预留能力              |
| Phase 6 | AI                 | 在稳定 IDE 基础上加入 AI Assistant；支持云端 API，同时提供适合平板运行的小型本地模型作为默认/离线方案 |

---

# 四、各阶段目标

### Phase 1 — IDE Workbench

目标是完成整个应用的“骨架”。

```text
LEFT                 CENTER                RIGHT

File Tree        Code Editor              AI
                     +
                  Terminal
```

这一阶段只调整 UI 架构，不修改 QEMU、Linux 和 Terminal 核心。

---

### Phase 2 — File System

目标是让 IDE 真正能够操作 HiSH Linux 环境中的项目文件。

通过：

```text
File Tree
    ↓
IDEFileSystem
    ↓
QemuAgent
    ↓
Linux VM
```

实现文件浏览、打开、新建、删除、重命名和保存。

---

### Phase 3 — Code Editor

目标是建立真正适合编程的编辑器，而不是普通文本框。

采用：

```text
ArkUI
  ↓
ArkWeb
  ↓
Monaco Editor
```

实现多文件 Tab、语法高亮、行号、搜索替换、Undo/Redo、代码折叠和 `Ctrl+S` 等基本 IDE 能力。

---

### Phase 4 — Terminal & Run

目标是打通完整开发闭环。

直接复用 HiSH 原有：

```text
WebTerminal
    ↓
xterm.js
    ↓
HiSH
    ↓
Linux VM
```

最终实现：

```text
打开 main.py
     ↓
编辑
     ↓
Ctrl+S
     ↓
保存到 Linux
     ↓
Run
     ↓
Terminal
     ↓
python3 main.py
```

完成这一阶段后，项目已经是一个真正可使用的轻量 IDE。

---

### Phase 5 — IDE & Plugin Framework

目标是从“能用”提升到“完整的开发工具”。

完善：

```text
File / Edit / View / Run / Terminal / Help
```

插件统一进入：

```text
File
└── Plugins
```

同时建立简单 Plugin API，为未来 Python、Git、Formatter、语言支持等功能提供扩展入口，但不复制 VS Code 庞大的 Extension Host。

---

### Phase 6 — AI Assistant

最后加入 AI。

架构保持独立：

```text
                 AI Assistant
                      │
                  AI Service
                 /          \
          Cloud API        Local AI
```

云端模型负责复杂代码生成、项目分析、Debug 和重构。

本地模型面向 PC/平板的离线场景，采用小型量化模型，主要负责基础代码解释、简单补全和局部修改。

AI 可以读取 Editor 当前文件、选中代码和 Terminal 错误，但**不直接侵入 Editor、Terminal 和 Linux Runtime 的核心实现**。

---

# 五、最终项目思想

整个项目可以概括为：

> **HiSH 提供 Linux，IDE 提供开发环境，AI 提供智能能力。**

即：

```text
HiSH IDE
│
├── IDE Layer
│   ├── File Tree
│   ├── Code Editor
│   ├── Terminal
│   └── Plugins
│
├── AI Layer
│   ├── Cloud Model
│   └── Local Small Model
│
└── HiSH Runtime
    ├── WebTerminal
    ├── QemuAgent
    ├── QEMU
    └── Linux VM
```

项目不追求一次性复制完整 VS Code，而采用**最小侵入、能力复用、模块解耦、逐步增强**的路线：首先把 HiSH 从“Linux 终端”扩展为“Linux 开发环境”，然后再从“开发环境”逐步扩展为“AI 辅助开发环境”。
