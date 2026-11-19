#!/bin/bash
# check.sh — arpfanout 部署前兼容性检查
# 只读检查 + 两条瞬时验证(lo 挂/删 clsact、试载/卸载 BPF 对象), 不留任何残留
cd "$(dirname "$0")"
PASS=0; FAIL=0
ok(){ echo "  [ OK ] $*"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
inf(){ echo "  [--]  $*"; }

echo "== 1. 内核 =="
KREL=$(uname -r)
MAJ=$(echo "$KREL" | awk -F. '{print $1}'); MIN=$(echo "$KREL" | awk -F. '{print $2}')
KV=$((MAJ*10000+MIN))
echo "  内核: $KREL ($(uname -m))"
[ "$KV" -ge 40005 ] && ok ">= 4.5 (clsact 从 4.5 起支持)" || no "< 4.5: 无 clsact qdisc, 无法部署"

echo "== 2. 权限/初始化 =="
[ "$(id -u)" = 0 ] && ok "root" || no "需 root 运行"
command -v systemctl >/dev/null && ok "systemd 存在" \
  || inf "无 systemd: 守护脚本可用 rc.local / nohup 方式运行(service 单元不适用)"

echo "== 3. 工具链 =="
command -v tc >/dev/null && ok "tc $(tc -V 2>&1 | head -1)" || no "缺 tc (Debian/Ubuntu: apt install iproute2; RHEL/Rocky等: dnf install iproute-tc)"
BPFTOOL_BIN=""
bpftool_works() { [ -x "$1" ] && "$1" version >/dev/null 2>&1; }
cand=$(command -v bpftool 2>/dev/null) || cand=""
if [ -n "$cand" ] && bpftool_works "$cand"; then
  BPFTOOL_BIN=$cand
  ok "bpftool $("$BPFTOOL_BIN" version 2>/dev/null | head -1)"
else
  # 当前内核的 wrapper 不可用(内核升级后 linux-tools 没跟上): 找已安装的真身兜底
  for cand in "/usr/lib/linux-tools/$(uname -r)/bpftool" \
              $(ls -1d /usr/lib/linux-tools/*/bpftool 2>/dev/null | sort -Vr 2>/dev/null); do
    if bpftool_works "$cand"; then BPFTOOL_BIN=$cand; break; fi
  done
  if [ -n "$BPFTOOL_BIN" ]; then
    inf "当前内核 $(uname -r) 的 bpftool 不可用, 运行时将兜底使用: $BPFTOOL_BIN"
    ok "bpftool $("$BPFTOOL_BIN" version 2>/dev/null | head -1)"
  else
    no "bpftool 不可用: apt install linux-tools-$(uname -r) (RHEL系: dnf install bpftool)"
  fi
fi
command -v clang >/dev/null && ok "clang $(clang --version | head -1 | awk '{print $3}')" \
  || inf "无 clang: x86_64 用预编译对象即可; 其他架构需要安装"

echo "== 4. 内核 BPF/tc 能力(瞬时验证) =="
if tc qdisc replace dev lo clsact 2>/dev/null; then
  tc qdisc del dev lo clsact 2>/dev/null
  ok "clsact egress 挂载验证通过"
else
  no "clsact 不可用(内核版本或 tc 缺 BPF 支持)"
fi
if mountpoint -q /sys/fs/bpf; then BPFS=yes; ok "bpffs 已挂载";
elif mount -t bpf bpf /sys/fs/bpf 2>/dev/null; then BPFS=yes; ok "bpffs 已挂载(本次新挂)";
else BPFS=no; no "bpffs 无法挂载"; fi
if [ "$BPFS" = yes ] && [ -f arpfanout.bpf.o ]; then
  if [ -z "$BPFTOOL_BIN" ]; then
    inf "bpftool 不可用, 跳过 BPF 对象加载验证"
  elif out=$("$BPFTOOL_BIN" prog load arpfanout.bpf.o /sys/fs/bpf/af_check 2>&1); then
    rm -f /sys/fs/bpf/af_check
    ok "BPF 对象实际加载验证通过 ($(uname -m))"
  else
    rm -f /sys/fs/bpf/af_check
    no "预编译对象加载失败, bpftool 原始报错:"
    printf '%s\n' "$out" | sed 's/^/         /'
    inf "x86_64 不需要现场编译; 先按上面的报错处理(bpftool/内核/权限)"
  fi
fi

echo "== 5. bond 环境(信息) =="
for d in /sys/class/net/*/bonding; do
  [ -d "$d" ] || continue
  b=$(basename "$(dirname "$d")")
  inf "bond $b: 模式=$(cat "$d/mode" 2>/dev/null) 成员=$(cat "$d/slaves" 2>/dev/null | tr '\n' ' ')"
done

echo
echo "结果: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "==> 兼容, 可部署: bash install.sh"
else
  echo "==> 存在 [FAIL] 项, 请先解决(见上)"
fi
exit $FAIL
