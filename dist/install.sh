#!/bin/bash
# arpfanout 离线安装脚本 — 目标机解压后 root 执行: bash install.sh
# 幂等: 重复执行 = 干净升级(先停服务卸旧, 再装新启动)
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
SBIN=/usr/local/sbin
LIBDIR=/usr/local/lib/arpfanout

say(){ echo "install: $*"; }

# 本设备 egress 上属于 arpfanout 的 filter: "pref handle" (每行一条)
our_filters() {
  tc filter show dev "$1" egress 2>/dev/null | awk '
    /^filter/ {
      pref = ""; handle = "";
      for (i = 1; i <= NF; i++) {
        if ($i == "pref")   pref = $(i + 1);
        if ($i == "handle") handle = $(i + 1);
      }
      if ($0 ~ /arpfanout/) print pref, handle;
    }'
}

# 只删 arpfanout 自己的 filter, 保留 clsact 及其他组件规则
del_our_filters() {
  local b=$1 pref handle
  our_filters "$b" | while read -r pref handle; do
    [ -n "$pref" ] || continue
    if [ -n "$handle" ]; then
      tc filter del dev "$b" egress pref "$pref" handle "$handle" bpf 2>/dev/null || true
    else
      tc filter del dev "$b" egress pref "$pref" bpf 2>/dev/null || true
    fi
    say "旧 filter 已摘: $b pref $pref${handle:+ handle $handle}"
  done
}

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
# 注意: Ubuntu 的 /usr/sbin/bpftool 只是 wrapper, 必须验证当前内核的工具真身可用;
# 只看 command -v 会把“wrapper 存在但 linux-tools 没装”误判为正常。
bpftool_works() { [ -x "$1" ] && "$1" version >/dev/null 2>&1; }
BPFTOOL=""
cand=$(command -v bpftool 2>/dev/null) || cand=""
if [ -n "$cand" ] && bpftool_works "$cand"; then
  BPFTOOL=$cand
else
  say "bpftool 不可用(常见于内核升级后 linux-tools 未跟上), 尝试自动安装 ..."
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
  cand=$(command -v bpftool 2>/dev/null) || cand=""
  if [ -n "$cand" ] && bpftool_works "$cand"; then BPFTOOL=$cand; fi
fi
# 仍不可用: 退到已安装的 linux-tools 真身(与 arpfanout 运行时探测顺序一致)
if [ -z "$BPFTOOL" ]; then
  for cand in "/usr/lib/linux-tools/$(uname -r)/bpftool" \
              $(ls -1d /usr/lib/linux-tools/*/bpftool 2>/dev/null | sort -Vr 2>/dev/null); do
    if bpftool_works "$cand"; then BPFTOOL=$cand; break; fi
  done
fi
[ -n "$BPFTOOL" ] || {
  echo "ERROR: bpftool 不可用 (运行内核 $(uname -r)): apt install linux-tools-$(uname -r) (或 dnf install bpftool)"
  exit 1
}
say "bpftool: $BPFTOOL"
# Ubuntu: 装 meta 包, 后续内核升级时自动带上对应的 linux-tools
if command -v apt-get >/dev/null && apt-cache show linux-tools-generic >/dev/null 2>&1; then
  dpkg -s linux-tools-generic >/dev/null 2>&1 || {
    say "安装 linux-tools-generic (后续内核升级自动跟随工具链) ..."
    apt-get install -y linux-tools-generic 2>/dev/null || true
  }
fi

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

# --- 4. 干净升级: 停服务; 精确摘除各 bond 上属于我们的 filter(名称+pref+handle),
#        保留 clsact 和其他组件的规则; 删 pin ---
systemctl stop arpfanout 2>/dev/null || true
if [ -e /sys/fs/bpf/arpfanout ]; then
  for d in /sys/class/net/*/bonding; do
    [ -d "$d" ] || continue
    b=$(basename "$(dirname "$d")")
    del_our_filters "$b"
  done
  rm -f /sys/fs/bpf/arpfanout
fi

# --- 5. 落盘(保留目标机已有的 /etc/default/arpfanout 配置, 不覆盖) ---
mkdir -p $LIBDIR
install -m 0644 "$OBJ" $LIBDIR/arpfanout.bpf.o
install -m 0644 "$SRC/arpfanout.bpf.c" $LIBDIR/arpfanout.bpf.c
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
N=$("$BPFTOOL" map dump name slave_tbl 2>/dev/null | grep -c 'bond' || true)
say "完成: bonds=[$BONDS] map条目≈$N"
say "回滚: arpfanout-remove | 卸载: arpfanout-uninstall | 日志: journalctl -u arpfanout -f"
