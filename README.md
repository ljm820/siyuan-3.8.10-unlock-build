# SiYuan 3.8.10 自编译 + 免登录同步解锁（Windows 11 x64）

对 [siyuan-note/siyuan](https://github.com/siyuan-note/siyuan) v3.8.10（AGPL-3.0 开源）在 Windows 11 上进行**源码原生编译**，
并参照 [appdev/siyuan-unlock](https://github.com/appdev/siyuan-unlock) 公开发布的 AGPL 补丁，实现**免登录使用本地同步功能（S3 / WebDAV）**。
本文记录从方案核对、补丁适配、编译打包到真机验证、系统部署的完整过程与全部脚本。

> **合规边界（先说清楚）**
> - 思源笔记客户端与内核均为 AGPL-3.0 开源，unlock 分支的修改也是公开的 AGPL 补丁；本仓库的改动仅作用于**本地运行的客户端代码**。
> - 解锁后的效果是：**不登录账号即可配置并使用你自己拥有的 S3 / WebDAV 存储做同步**（这类同步不消耗官方云资源）。
> - 该方案**不能也无法**伪造官方云服务会话——unlock 补丁自带的测试明确断言"云端请求依然返回认证失败"。官方云同步仍需真实账号与订阅。

---

## 一、unlock 解锁方案复核（机制分析）

`appdev/siyuan-unlock` 仓库的 `patches/siyuan/` 目录存放其全部桌面端补丁（构建时应用到官方源码）：

| 补丁 | 作用 | 关键改动 |
|---|---|---|
| **mock-vip-user.patch**（核心） | 免登录解锁同步 | 内核 `getCloudUser` API 不再请求云端，改为**生成本地合成用户**：`UserId="0"`、`UserSiYuanSubscriptionType=1`、`UserSiYuanOneTimePayStatus=1`（付费态）、过期时间 -1（永不过期）；AES 加密写入 `conf.json` 的 `userData` 持久化，重启不丢。内核侧 `IsPaidUser()` 恒真 → S3/WebDAV 同步的付费门禁打开 |
| mock-vip-user.patch（配套） | 身份保护 | `cloud_account_auth.go`：云端认证失败**不清除**本地身份（UserId="0" 且 token="token" 的哨兵值直接 no-op）；`cloud_service.go`：移除 2 小时周期的 `refreshUser` 云端刷新 |
| default-config.patch | 默认配置 | 默认同步 Provider 从官方云改为 **S3**（用户自己的存储）；冲突文档默认开启；界面默认 zh_CN；关闭按钮默认最小化到托盘 |
| hide-account-entry.patch | 界面适配 | 设置页移除"账号"分组；顶栏账号/会员按钮不再弹登录 |
| disable-update.patch | 更新控制 | 关闭官方安装包自动下载；更新检查源指向 unlock 仓库 releases |
| first-launch-notice.patch | fork 声明页 | 防倒卖声明弹窗（**非解锁机制，本构建跳过**） |

**要点**：这套方案的本质是把"付费用户"判定从"向云端查询"改为"本地合成"，解锁的是**客户端侧的功能门禁**；
同步目标存储完全由用户自配（S3/WebDAV 均为用户自有资源），不涉及官方云服务的盗用。

## 二、构建环境（本机实测所用）

- Windows 11 x64（10.0.26200）
- Go 1.27.0（内核，CGO 必须：sqlite 使用 88250/go-sqlite3 fork，tags `fts5 sqlcipher`）
- MinGW-w64 gcc（CGO 编译器）
- Node v24.10.0 + pnpm 12.6.0（`packageManager` 字段自管版本）
- electron-builder 26.18.0（zip + nsis 双目标）
- Python 3（仅 OCR 资源准备脚本用）

## 三、构建步骤

### 1. 获取源码（worktree 隔离，不污染 3.8.9 旧构建树）

```bash
git fetch origin tag v3.8.10 --no-tags
git worktree add ../siyuan-3.8.10 v3.8.10   # commit be17ed1e05
```

### 2. 应用解锁补丁

unlock 的补丁基于其构建时的官方源码快照，直接 `git apply` 有 3 处上下文漂移。
本仓库 `patches/siyuan-3.8.10-unlock-adapted.patch` 是适配后的最终差异（对 v3.8.10 可一次 `git apply`）：

```bash
git apply siyuan-3.8.10-unlock-adapted.patch
```

适配明细：
- `mock-vip-user.patch`、`disable-update.patch`：官方 v3.8.10 上**干净应用**
- `default-config.patch`：`kernel/conf/appearance.go` 字段名/结构漂移（3.8.10 增加 BodyGradient 等），`kernel/conf/sync.go` 同 hunk 连带失败 → 手工改 `Lang: "zh_CN"`、`CloseButtonBehavior: 1`、`GenerateConflictDoc: true`、`Provider: ProviderS3`
- `hide-account-entry.patch`：`syncTab.ts` 导入列表漂移、`topBar.ts` 上下文行漂移 → 手工删除 `registerAccountGroup` 导入与调用、删除顶栏 `toolbarVIP` 分支的 `openSetting(app, "sync")` 及其未使用导入
- `first-launch-notice.patch`：fork 防倒卖声明，非解锁机制 → **跳过**

### 3. 编译内核

```bash
cd siyuan-3.8.10/kernel
export PATH="<mingw64>/bin:$PATH"
export CGO_ENABLED=1 CC=gcc GOOS=windows GOARCH=amd64
go build -tags "fts5 sqlcipher" -ldflags "-s -w" -o ../app/kernel/SiYuan-Kernel.exe .
# 产物 ~154MB；版本号固化在 kernel/util/working.go: const Ver = "3.8.10"
```

### 4. 准备 OCR 资源（随包分发，离线可用）

官方 `beforePack` 会执行 `scripts/prepare-ocr.py` 下载 PaddleOCR ONNX 模型 + onnxruntime，
并要求从"已许可的 VS Redist"取 VC 运行库随包。无 VS 安装时用环境变量指路：

```bash
# 从 System32 拷贝 release 版 VC 运行库到合规目录结构
mkdir -p tools/vc-redist/x64/Microsoft.VC14.CRT
# msvcp140.dll msvcp140_1.dll msvcp140_2.dll msvcp140_atomic_wait.dll
# msvcp140_codecvt_ids.dll vcruntime140.dll vcruntime140_1.dll vcruntime140_threads.dll concrt140.dll
export SIYUAN_OCR_VC_REDIST_DIR="D:\...\tools\vc-redist"
python -I scripts/prepare-ocr.py --runtime windows-amd64   # 产物 ~22MB 入 app/stage/ocr
```

### 5. 构建前端 + 打包

```bash
cd siyuan-3.8.10/app
export PATH="<node24>:$PATH"
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
export ELECTRON_BUILDER_BINARIES_MIRROR=https://npmmirror.com/mirrors/electron-builder-binaries/
export SIYUAN_OCR_VC_REDIST_DIR="D:\...\tools\vc-redist"

pnpm install
pnpm run build     # ⚠️ 必须：完整前端构建，生成 stage/build/app/index.html
                   #    官方 dist 脚本只跑 build:electron，漏掉这步主窗口白屏！
pnpm run dist      # electron-builder → build/siyuan-3.8.10-win.zip + build/siyuan-3.8.10-win.exe
```

`electron-builder.yml` 增加 zip 目标（官方只有 nsis）：

```yaml
  target:
    - target: "nsis"
    - target: "zip"
```

**踩坑记录**：
1. **漏 `pnpm run build` → 主窗口白屏**：官方 CI（desktop-build.yml:127）先跑完整 build 再 dist；dist 脚本自身只编译 Electron 主进程。白屏时窗口标题只有 "SiYuan"，正常加载后为 `<工作空间> - SiYuan v3.8.10`。
2. **beforePack 重复跑 prepare-ocr**：环境变量 `SIYUAN_OCR_VC_REDIST_DIR` 必须在 dist 命令的 shell 里也导出，否则 again 失败。
3. **zip 目标产物无顶层前缀**（electron-builder 默认行为），解压即得应用文件本体。

## 四、产物

| 文件 | 大小 | 说明 |
|---|---|---|
| `siyuan-3.8.10-win.zip` | ~304MB | Win11 便携 zip（发布形式） |
| `siyuan-3.8.10-win.exe` | ~239MB | NSIS 安装包（用于静默部署更新） |

## 五、验证结果（本机 Win11 真机）

1. **zip 解压即用**：解压到独立目录，`SiYuan.exe --workspace=<测试工作空间>` 启动
2. **内核**：`kernel booted`，`fixed port service [127.0.0.1:6806] is running (HTTP/HTTPS dual mode)`，`/check-auth` 返回授权页
3. **UI**：窗口标题 `<工作空间> - SiYuan v3.8.10`，引导文档自动创建并索引，无 UI 进程告警
4. **免登录解锁**：不登录任何账号，设置 → 同步 中 S3 / WebDAV 可选可用（付费门禁已开）；内核 `getCloudUser` 返回本地合成身份并持久化（重启后仍为付费态）
5. **官方云服务隔离**：合成身份的 token 为哨兵值，任何对官方云的请求仍会得到认证失败（unlock 补丁测试同款断言）

## 六、部署更新到本机

```powershell
# 关闭运行中的思源后静默安装（NSIS 会沿用已有安装目录 D:\ProgramFiles\SiYuan）
.\siyuan-3.8.10-win.exe /S
```

安装后校验：`SiYuan.exe` 版本 3.8.10；工作空间数据（`Documents\SiYuan`）与配置不受影响。

## 七、目录结构

```
patches/
  siyuan-3.8.10-unlock-adapted.patch   # 适配官方 v3.8.10 的最终解锁差异（本构建实际应用）
  unlock-upstream/                     # appdev/siyuan-unlock 原始补丁存档（AGPL）
scripts/
  build-all.sh                         # 一键构建脚本
README.md                              # 本文档
```

## 八、致谢与许可

- [siyuan-note/siyuan](https://github.com/siyuan-note/siyuan)：AGPL-3.0
- [appdev/siyuan-unlock](https://github.com/appdev/siyuan-unlock)：解锁补丁方案来源，AGPL-3.0

本仓库所有内容遵循 AGPL-3.0。仅供个人本地使用与研究，请尊重思源笔记官方的订阅服务。
