#!/bin/bash
# test_10bonds.sh — 10 bond 压力测试: 用 20 个 veth 造 10 个 bond(每个2成员),
# 同一 netns 内模拟(不需要真实对端, active-backup 模式, 用 dummy 对端即可)
# 验证: (a) sync 把 10 个 bond 全部挂载、20 个成员表项全部正确
#       (b) 每个 bond 的 ARP 都双发(抽验全部 10 个, 每个应看到 2 成员口各一份)
#       (c) 收敛性能(10 bond 时 sync 耗时)
# 测完完全清理, 不留残留
set -u
NETNS=af10
BPRE=afb
VPRE=afv

cleanup() {
  for i in $(seq 0 9); do ip link del ${BPRE}$i 2>/dev/null; done
  for i in $(seq 0 19); do ip link del ${VPRE}$i 2>/dev/null; done
  ip netns del $NETNS 2>/dev/null
  systemctl restart arpfanout 2>/dev/null
}
trap cleanup EXIT

echo "== 造 10 个 bond(每个 2 成员, active-backup, 不需要真实对端) =="
ip netns add $NETNS
for i in $(seq 0 9); do
  ip link add ${BPRE}$i type bond mode active-backup miimon 100 2>/dev/null
  for j in 0 1; do
    n=$((i*2+j))
    ip link add ${VPRE}$n type veth peer name p$n netns $NETNS
    ip link set ${VPRE}$n master ${BPRE}$i up
  done
  ip addr add 10.$((100+i)).1.1/24 dev ${BPRE}$i
  ip link set ${BPRE}$i up
done
echo "bond 数量: $(ls -d /sys/class/net/${BPRE}* 2>/dev/null | wc -l)"

echo
echo "== sync 收敛(计时) =="
T0=$(date +%s.%N)
systemctl restart arpfanout
T1=$(date +%s.%N)
sleep 1
journalctl -u arpfanout --no-pager -n 1 -o cat
echo "sync 耗时: $(echo "$T1 $T0" | awk '{printf "%.2fs", $1-$2}')"

echo
echo "== 挂载与表项完整性 =="
ATTACHED=0
for i in $(seq 0 9); do
  tc filter show dev ${BPRE}$i egress 2>/dev/null | grep -q arpfanout && ATTACHED=$((ATTACHED+1))
done
ENTRIES=$(bpftool map dump name slave_tbl 2>/dev/null | grep -c '"slot"')
echo "挂载: $ATTACHED/10 | 成员表项: $ENTRIES/20"

echo
echo "== 抓包验证(每个 bond 触发 ARP, 数两个成员口各自的帧数) =="
PASS=0; FAIL=0
for i in $(seq 0 9); do
  a=${VPRE}$((i*2)); b=${VPRE}$((i*2+1))
  MAC=$(cat /sys/class/net/${BPRE}$i/address)
  ( ping -c 2 -W 1 10.$((100+i)).1.254 >/dev/null 2>&1 ) &
  sleep 0.15
  CA=$(timeout 3 tcpdump -i $a -en -c 2 "ether src $MAC and arp" 2>/dev/null | wc -l)
  CB=$(timeout 3 tcpdump -i $b -en -c 2 "ether src $MAC and arp" 2>/dev/null | wc -l)
  if [ "$CA" -ge 1 ] && [ "$CB" -ge 1 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "  FAIL: ${BPRE}$i ($a=$CA, $b=$CB)"
  fi
done
echo
echo "== 串扰检查: 只触发 afb3 的 ARP, 全部 20 个口抓包, 断言只有 afv6/afv7 见到帧 =="
mkdir -p /tmp/af10; rm -f /tmp/af10/*
for i in $(seq 0 19); do
  timeout 4 tcpdump -i ${VPRE}$i -en -c 1 \
    "ether src $(cat /sys/class/net/${BPRE}3/address) and arp" \
    -w /tmp/af10/cap$i.pcap 2>/dev/null &
done
sleep 0.3
( ping -c 3 -W 1 10.103.1.254 >/dev/null 2>&1 ) &
wait
LEAK=0; OK2=0
for i in $(seq 0 19); do
  n=$(tcpdump -nr /tmp/af10/cap$i.pcap 2>/dev/null | wc -l)
  case $i in
    6|7) [ "$n" -ge 1 ] && OK2=$((OK2+1)) || echo "  FAIL: afv$i (afb3 自己的成员口!) 未见帧";;
    *)   [ "$n" -ge 1 ] && { LEAK=$((LEAK+1)); echo "  LEAK: afv$i (别的bond的成员) 出现了 afb3 的 ARP!"; } ;;
  esac
done
rm -rf /tmp/af10
echo "afb3 的 ARP: 自己两口见到 $OK2/2, 外泄到其他成员口 $LEAK 处"

echo
echo "结果: $PASS/10 个 bond 双发 PASS, $FAIL FAIL"
[ "$FAIL" = 0 ] && [ "$ATTACHED" = 10 ] && [ "$ENTRIES" = 20 ] \
  && echo "==> 10-bond 压测通过" || echo "==> 存在失败项(见上)"
exit $([ "$FAIL" = 0 ] && [ "$ATTACHED" = 10 ] && [ "$ENTRIES" = 20 ]; echo $?)
