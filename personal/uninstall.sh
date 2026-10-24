#!/bin/bash
# 停止并移除服务（TUN 随之撤销）。用法：sudo ./uninstall.sh
exec env NAME=neu-v6-router LABEL=com.nk.neu-v6-router "$(cd "$(dirname "$0")" && pwd)/../mac/uninstall.sh"
