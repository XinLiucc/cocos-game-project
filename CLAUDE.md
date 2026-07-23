# 项目须知（Claude Code 跨设备通用约定）

本文件跟随 git 仓库，在任何设备打开这个项目时都应遵守，避免设计决策/约定丢失。

## 项目定位
- 参考 `PLAN.md` —— 它是项目决策、核心循环、TODO 的唯一权威来源，任何设计问题先看这个文件的最新状态，不要凭旧记忆假设。
- 当前重点是"汽车修理厂"练手项目，纯学习题材，目的是跑通 Cocos Creator 全流程，不追求题材本身出彩。

## 开发环境与工作流
- 引擎：Cocos Creator（TypeScript），无官方 Linux 版编辑器。
- 用户采用双系统分工：**代码编写在 Ubuntu（用 Claude Code + git）**，**Cocos Creator 编辑器在 Windows 那边跑**（场景搭建、拖资源、导出），两边通过 git 仓库（`git@github.com:XinLiucc/cocos-game-project.git`）同步，不需要在 Windows 上配置 Node/Java 等工具链。

## 协作约定
- **Git commit 信息一律用英文**；项目文档（PLAN.md 等）一律用中文。用户在用英语学习/练习作为顺带目的。
- **设计决策不要催促定论**：核心循环、数值、美术风格等属于慢慢打磨的过程，用户明确表示不想一蹴而就。给出选项和建议即可，让决策留白，跟随用户节奏推进。
- 用户是独立开发者，对 Cocos Creator 是新手（此前接触过 Godot 和 Cocos 但没有 Cocos Creator 实操经验），解释技术概念时不要假设已有该引擎的使用经验。
