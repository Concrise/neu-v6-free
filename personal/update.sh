#!/bin/bash
# 用通用版（上一级目录）重新生成 mac 配置并热更新已安装的服务。用法：./update.sh（不用 sudo，交给已安装的本地助手）
# 沿用旧安装的服务名与目录（com.nk.neu-v6-router、/usr/local/*/neu-v6-router），测速/诊断/监测脚本都依赖它们
set -euo pipefail
cd "$(dirname "$0")"
NAME=neu-v6-router LABEL=com.nk.neu-v6-router OUT=out exec ../mac/update.sh -c profile.yaml -c config.local.yaml
