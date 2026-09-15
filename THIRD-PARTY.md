# 第三方组件说明

本仓库**不包含任何第三方二进制文件**，也不包含任何"可自动联网下载并自动补全"的脚本。
仓库里只有本工具自己的源代码与文档。

## 工具在运行时会用到的第三方组件

工具只做**状态检测**与**调用**，不重新分发这些组件。你需要自行获取，
并把它们放进 `offline\` 目录（或使用系统里已安装的版本）。

| 组件 | 作者 / 提供方 | 用途 | 许可 |
| --- | --- | --- | --- |
| Microsoft Visual C++ Redistributable 2005–2022 | Microsoft | 东方系列依赖的 VC 运行库（x86 与 x64 分开） | 微软可再分发条款 |
| Microsoft DirectX End-User Runtime (Jun2010) | Microsoft | D3DX9 / XAudio2 / XInput 等 DirectX 组件 | 微软可再分发条款 |
| DirectX SDK 中的 D3DX 系列 | Microsoft | 部分作品需要的 D3DX 扩展库 | 微软可再分发条款 |
| dgVoodoo2 | Dege | 把 DirectX 8/9 调用转换为 Direct3D 11，用于老显卡/新系统兼容 | 见其自带许可 |
| Locale Emulator | xupefei | 转区运行日文游戏 | 见其自带许可 |

## 关于 DirectX Repair

本工具在实现过程中参考了 **DirectX Repair**（作者 zhangyue667）的功能划分，
并可以对**你自己机器上已安装的** DirectX Repair 的 `Data` 目录做完整性补全
（`tools\Complete-DirectXRepair.ps1`）。

该脚本**只在本地读写你自己已有的文件，不联网、不下载**。
DirectX Repair 本身及其数据包不包含在本仓库中，其版权归原作者所有。

## 关于运行库的分发

微软 Visual C++ Redistributable 与 DirectX End-User Runtime 属于可再分发组件，
但其分发仍受微软条款约束。本仓库选择**不分发**任何这类二进制文件，
以确保仓库内容干净、体积小、且不涉及再分发条款问题。
