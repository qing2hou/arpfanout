#!/bin/bash
# arpfanout 离线安装脚本 — 目标机解压后 root 执行: bash install.sh
# 幂等: 重复执行 = 干净升级(先停服务卸旧, 再装新启动)
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
SBIN=/usr/local/sbin
LIBDIR=/usr/local/lib/arpfanout

say(){ echo "install: $*"; }
[ "$(id -u)" = 0 ] || { echo "ERROR: 需要 root 运行"; exit 1; }

# --- 1. 依赖: tc + bpftool(缺则按发行版自动装一次) ---
# 注意: tc 的包名按发行版不同 —— Debian/Ubuntu: iproute2; RHEL/Rocky/openEuler 等: iproute-tc
if ! command -v tc >/dev/null; then
  say "tc 缺失, 尝试自动安装 ..."
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 2>/dev/null || true
  elif command -v dnf >/dev/null; then
    dnf install -y iproute-tc 2>/dev/null || true
  elif command -v yum >/dev/null; then
    yum install -y iproute-tc 2>/dev/null || true
  elif command -v zypper >/dev/null; then
    zypper --non-interactive install iproute2 2>/dev/null || true
  fi
fi
command -v tc >/dev/null || { echo "ERROR: tc 不可用 (Debian/Ubuntu: apt install iproute2; RHEL/Rocky/openEuler: dnf install iproute-tc)"; exit 1; }
if ! command -v bpftool >/dev/null; then
  say "bpftool 缺失, 尝试自动安装 ..."
  if command -v apt-get >/dev/null; then
    apt-get install -y linux-tools-common "linux-tools-$(uname -r)" 2>/dev/null \
      || apt-get install -y linux-tools-common linux-tools-generic 2>/dev/null || true
  elif command -v dnf >/dev/null; then
    dnf install -y bpftool 2>/dev/null || true
  elif command -v yum >/dev/null; then
    yum install -y bpftool 2>/dev/null || true
  elif command -v zypper >/dev/null; then
    zypper --non-interactive install bpftool 2>/dev/null || true
  fi
fi
command -v bpftool >/dev/null || { echo "ERROR: bpftool 不可用 (Ubuntu: apt install linux-tools-\$(uname -r); RHEL/openEuler: dnf install bpftool)"; exit 1; }

# --- 2. bpffs ---
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf

# --- 3. BPF 对象: 默认装预编译(x86_64, 无 CO-RE 依赖, 4.x+ 内核通用);
#        非 x86_64 且本机有 clang 则现场编译 ---
OBJ="$SRC/arpfanout.bpf.o"
ARCH=$(uname -m)
if [ "$ARCH" != x86_64 ]; then
  TARCH=arm64; [ "$ARCH" = aarch64 ] || TARCH=$ARCH
  if command -v clang >/dev/null; then
    say "非 x86_64 ($ARCH), 用 clang 现场编译 ..."
    clang -O2 -g -target bpf -D__TARGET_ARCH_$TARCH \
      -I/usr/include/$ARCH-linux-gnu -c "$SRC/arpfanout.bpf.c" -o /tmp/arpfanout.$$.o
    OBJ=/tmp/arpfanout.$$.o
  else
    echo "ERROR: 预编译对象只覆盖 x86_64; $ARCH 需装 clang 后重跑本脚本"; exit 1
  fi
fi

# --- 4. 干净升级: 停服务; 只摘除各 bond 上属于我们的 filter(按 pref 精确删, 不动其他组件的); 删 pin ---
systemctl stop arpfanout 2>/dev/null || true
if [ -e /sys/fs/bpf/arpfanout ]; then
  for d in /sys/class/net/*/bonding; do
    [ -d "$d" ] || continue
    b=$(basename "$(dirname "$d")")
    for P in $(tc filter show dev "$b" egress 2>/dev/null | grep arpfanout \
               | grep -o 'pref [0-9]*' | awk '{print $2}' | sort -u); do
      tc filter del dev "$b" egress pref "$P" 2>/dev/null || true
      say "旧 filter 已摘: $b pref $P"
    done
  done
  rm -f /sys/fs/bpf/arpfanout
fi

# --- 5. 落盘(保留目标机已有的 /etc/default/arpfanout 配置, 不覆盖) ---
mkdir -p $LIBDIR
install -m 0644 "$OBJ" $LIBDIR/arpfanout.bpf.o
install -m 0755 "$SRC/arpfanout" $SBIN/arpfanout
install -m 0755 "$SRC/arpfanout-remove" $SBIN/
install -m 0755 "$SRC/arpfanout-uninstall" $SBIN/
install -m 0644 "$SRC/arpfanout.service" /etc/systemd/system/arpfanout.service
[ -f /etc/default/arpfanout ] || install -m 0644 "$SRC/arpfanout.env" /etc/default/arpfanout

# --- 6. 启动 + 冒烟 ---
systemctl daemon-reload
systemctl enable --now arpfanout
sleep 2
if ! systemctl is-active --quiet arpfanout; then
  echo "ERROR: 服务未运行, 请查 journalctl -u arpfanout -n 20"; exit 1
fi
BONDS=$(for d in /sys/class/net/*/bonding; do basename "$(dirname "$d")"; done | tr '\n' ' ')
N=$(bpftool map dump name slave_tbl 2>/dev/null | grep -c 'bond' || true)
say "完成: bonds=[$BONDS] map条目≈$N"
say "回滚: arpfanout-remove | 卸载: arpfanout-uninstall | 日志: journalctl -u arpfanout -f"
