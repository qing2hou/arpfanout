#!/bin/bash
# deploy_hosts.sh — 从本机(跳板)批量部署 arpfanout 到多台目标机
#
# 用法:
#   1. 准备 hosts.txt(与本脚本同目录), 一行一个目标 IP 或 "user@ip"
#      (井号开头为注释); 或者直接把主机当参数传
#   2. bash deploy_hosts.sh                      # 部署 hosts.txt 全部(自动选目录下最新包)
#      bash deploy_hosts.sh 192.0.2.11 192.0.2.12   # 临时指定
#      bash deploy_hosts.sh -p <密码> ...         # 密码统一时免交互
#      bash deploy_hosts.sh -u ops ...            # 非 root 用户(需有免密 sudo)
#      bash deploy_hosts.sh -f arpfanout-1.6.tar.gz ...
#
# 流程(每台): scp 包 → check.sh 兼容检查 → install.sh 安装 → test_v6.sh 验证
# 幂等: 重复执行=升级(已装的机器会干净重装)
set -u
PKG=""
HERE="$(cd "$(dirname "$0")" && pwd)"
USERARG=; PASS="${SSHPASS:-}"

HOSTS=()
[ -f "$HERE/hosts.txt" ] && mapfile -t HOSTS < <(grep -vE '^\s*(#|$)' "$HERE/hosts.txt")
while [ $# -gt 0 ]; do
  case $1 in
    -p) PASS=$2; shift 2;;
    -u) USERARG=$2; shift 2;;
    -f) PKG=$2; shift 2;;
    -*) echo "未知参数 $1"; exit 2;;
    *)  HOSTS+=("$1"); shift;;
  esac
done
[ ${#HOSTS[@]} -ge 1 ] || { echo "用法: bash $0 [-p 密码] [-u 用户] [-f 包] <ip...|(hosts.txt)>"; exit 2; }
# 未指定 -f 时自动取脚本目录/当前目录/root 下版本号最新的包
if [ -z "$PKG" ]; then
  for d in "$HERE" "$PWD" /root; do
    PKG=$(ls "$d"/arpfanout-*.tar.gz 2>/dev/null | sort -V | tail -1)
    [ -n "$PKG" ] && break
  done
fi
[ -n "$PKG" ] && [ -f "$PKG" ] || { echo "缺少安装包 ${PKG:-arpfanout-*.tar.gz} (用 -f 指定)"; exit 2; }
PKGBASE=$(basename "$PKG")
DIR=${PKGBASE%.tar.gz}
command -v sshpass >/dev/null || { echo "缺少 sshpass: apt install -y sshpass (或 dnf/yum install sshpass)"; exit 2; }
[ -z "$PASS" ] && { read -rsp "SSH 密码: " PASS; echo; }

OK=(); BAD=()
for h in "${HOSTS[@]}"; do
  u=$USERARG; case $h in *@*) u=${h%%@*}; h=${h##*@};; esac
  u=${u:-root}
  SUDO=""; [ "$u" != root ] && SUDO="sudo"
  echo "=============== $u@$h ==============="
  if SSHPASS="$PASS" sshpass -e scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$PKG" "$u@$h:/tmp/" \
  && SSHPASS="$PASS" sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$u@$h" \
       "cd /tmp && rm -rf '$DIR' && tar xzf '$PKGBASE' && cd '$DIR' && \
        bash check.sh && $SUDO bash install.sh && $SUDO bash test_v6.sh"; then
    OK+=("$h")
  else
    BAD+=("$h"); echo ">>> $h 部署失败(看上方输出)"
  fi
done

echo
echo "======== 汇总: 成功 ${#OK[@]} 台 / 失败 ${#BAD[@]} 台 ========"
[ ${#OK[@]}  -gt 0 ] && echo "成功: ${OK[*]}"
[ ${#BAD[@]} -gt 0 ] && echo "失败: ${BAD[*]} (可单台排查后重跑, 幂等)"
