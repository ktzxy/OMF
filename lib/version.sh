#!/bin/bash
# OMF - 版本号单一来源 (唯一需要修改版本号的地方)
# 由 omf.sh / setup.sh / 其它模块 source 引用, 避免多处硬编码不同步。
# 更新版本号时: 只改这里, 并同步更新 docs/CHANGELOG.md 最新条目。
OMF_VERSION="1.66"
export OMF_VERSION
