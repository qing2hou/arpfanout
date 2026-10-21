#!/bin/bash
# test_v6.sh — arpfanout IPv6 NDP 双发一键验证
# 用法: bash test_v6.sh [bond名]     (不指定则取系统第一个 bond)
# 判定: 本机发出的 NDP 帧(NS/NA/RS/RA)在每个成员口都出现相同副本 => PASS
#
# 三种触发(互为补充, 任一生效即可判定):
#   1. DAD: 加临时 ULA 地址 → 必发组播 NS(不依赖任何外部网络)
#   2. 网关探测: 删 v6 网关表项 + ping → NS/NA
#   3. ndisc6 工具直接发 NS(若安装了 ndisc6)
set -u

BOND="${1:-}"
if [ -z "$BOND" ]; then
  for d in /sys/class/net/*/bonding; do
    [ -d "$d" ] && { BOND=$(basename "$(dirname "$d")"); break; }
  done
fi
[ -n "${BOND:-}" ] && [ -d "/sys/class/net/$BOND/bonding" ] \
  || { echo "ERROR: 未找到 bond: ${BOND:-?}"; exit 2; }

M=($(cat "/sys/class/net/$BOND/bonding/slaves"))
[ ${#M[@]} -ge 2 ] || { echo "ERROR: $BOND 成员不足两个"; exit 2; }
M1=${M[0]}; M2=${M[1]}
MAC=$(cat "/sys/class/net/$BOND/address")
TMP=fd99:1:2:3::99
CAPT=15

trap 'ip address del $TMP/128 dev "$BOND" 2>/dev/null' EXIT

echo "== IPv6 NDP 双发测试 =="
echo "bond=$BOND  members=$M1 $M2  mac=$MAC"

PC1=/tmp/ndp_$M1.pcap; PC2=/tmp/ndp_$M2.pcap
rm -f "$PC1" "$PC2"
FILT="ether src $MAC and (icmp6 or (vlan and icmp6))"

timeout $CAPT tcpdump -i "$M1" -en -w "$PC1" $FILT 2>/dev/null & T1=$!
timeout $CAPT tcpdump -i "$M2" -en -w "$PC2" $FILT 2>/dev/null & T2=$!
sleep 1.5

echo "-- 触发1: DAD(临时地址 $TMP → 组播 NS) --"
ip address add "$TMP/128" dev "$BOND" 2>/dev/null
sleep 2

echo "-- 触发2: v6 网关表项删除 + 探测 --"
GW=$(ip -6 route show default | awk '{print $3; exit}')
if [ -n "${GW:-}" ]; then
  ip -6 neigh del "$GW" dev "$BOND" 2>/dev/null
  P=$GW; case $GW in fe80:*) P="$GW%$BOND";; esac
  ping -6 -c 1 -W 1 "$P" >/dev/null 2>&1
  command -v ndisc6 >/dev/null && ndisc6 "$GW" "$BOND" >/dev/null 2>&1
  echo "   (网关 $GW)"
else
  echo "   (无 v6 默认路由, 跳过)"
fi

wait $T1 $T2 2>/dev/null
ip address del "$TMP/128" dev "$BOND" 2>/dev/null

NDP='neighbor solicitation|neighbor advertisement|router solicitation|router advertisement'
norm() { tcpdump -nr "$1" -en 2>/dev/null | grep -E "$NDP" | sed -E 's/^[0-9:.]+ //' | sort; }
A=/tmp/ndp_a.$$; B=/tmp/ndp_b.$$
norm "$PC1" > $A; norm "$PC2" > $B

echo "== $M1 发出的 NDP =="; cat $A
echo "== $M2 发出的 NDP =="; cat $B

C1=$(wc -l < $A); C2=$(wc -l < $B)
COMMON=$(comm -12 $A $B | wc -l)
rm -f $A $B "$PC1" "$PC2"

echo
if [ "$COMMON" -ge 1 ]; then
  echo "PASS: $COMMON 个 NDP 帧在两个成员口各发出一份 ($M1=$C1 帧, $M2=$C2 帧)"
  comm -12 /dev/stdin /dev/stdin </dev/null 2>/dev/null  # noop
  exit 0
else
  echo "FAIL: 未见两口同时发出的相同 NDP 帧 ($M1=$C1, $M2=$C2)"
  if [ "$C1" = 0 ] && [ "$C2" = 0 ]; then
    echo "提示: 两口均未抓到 NDP。可能: DAD 被禁用(net.ipv6.conf.*.dad_transmits=0)且无 v6 网关。"
    echo "      手动触发: ndisc6 <某v6地址> $BOND  (apt install ndisc6 / dnf install ndisc6)"
  elif [ "$C1" = 0 ] || [ "$C2" = 0 ]; then
    echo "提示: 只有一个口有 NDP — 双发未生效或 map 未涵盖该 bond"
    echo "      检查: systemctl is-active arpfanout; bpftool map dump name slave_tbl"
  fi
  exit 1
fi
