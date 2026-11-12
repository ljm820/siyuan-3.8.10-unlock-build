#!/bin/bash
# SiYuan 3.8.10 unlock build — 一键构建（Git Bash / Windows 11 x64）
# 用法: 在 repo 根(siyuan-3.8.10 worktree 的父目录)执行
set -e

TOOLS=/d/ProgramData/ArtCraft_Prjs/tools
WT=/d/ProgramData/ArtCraft_Prjs/siyuan-3.8.10
VC_REDIST='D:\ProgramData\ArtCraft_Prjs\tools\vc-redist'

export PATH="$TOOLS/mingw64/bin:$TOOLS/node-v24.10.0-win-x64:$PATH"
export CGO_ENABLED=1 CC=gcc GOOS=windows GOARCH=amd64
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
export ELECTRON_BUILDER_BINARIES_MIRROR=https://npmmirror.com/mirrors/electron-builder-binaries/
export SIYUAN_OCR_VC_REDIST_DIR="$VC_REDIST"

echo "== 1. 应用解锁补丁 =="
cd "$WT"
git apply --check ../siyuan-unlock-build/patches/siyuan-3.8.10-unlock-adapted.patch
git apply  ../siyuan-unlock-build/patches/siyuan-3.8.10-unlock-adapted.patch

echo "== 2. 编译内核 =="
cd "$WT/kernel"
go build -tags "fts5 sqlcipher" -ldflags "-s -w" -o ../app/kernel/SiYuan-Kernel.exe .

echo "== 3. OCR 资源(已有可跳过) =="
cd "$WT"
python -I scripts/prepare-ocr.py --runtime windows-amd64 || echo "OCR already prepared / skipped"

echo "== 4. 前端完整构建 =="
cd "$WT/app"
pnpm install
pnpm run build

echo "== 5. electron-builder 打包(zip+nsis) =="
pnpm run dist

echo "== 完成 =="
ls -la build/siyuan-3.8.10-win.zip build/siyuan-3.8.10-win.exe
