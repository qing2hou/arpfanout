# arpfanout

**802.3ad bond 成员口 ARP/NDP 双发** —— 面向去堆叠（de-stacked）双上联架构的 eBPF/tc 方案。

在"两台独立 leaf（无堆叠/无 MLAG）+ 服务器 802.3ad bond 双上联"的架构中，内核 bonding
驱动只按哈希从**一个**成员口发出 ARP/NDP，另一侧 leaf 学不到主机表项，回程流量哈希到它时
就会黑洞。本方案用 eBPF（tc egress，挂在 bond 主设备）把每个 ARP/NDP 帧**克隆到该 bond 的
每个成员口**，让两张 leaf 都在自己直连链路上学到主机——把"表项同步"的职责从交换机侧
（堆叠/MLAG）转移到主机侧，而不需要修改内核或魔改 bonding 驱动。

```
             ┌─── en0 ─── leaf-A ┐
  应用/内核  │                   ├─ 去堆叠 fabric（两台 leaf 互相独立、无表项同步）
  bond0 ─────┤                   │
  bond0.40   └─── en1 ─── leaf-B ┘

  原生行为:  ARP ──哈希──▶ en0（只发一份，leaf-B 学不到）
  本方案:    ARP ──eBPF──▶ en0 + en1（各一份，两张 leaf 都学到）
```

## 特性

- **IPv4 ARP + IPv6 NDP（RS/RA/NS/NA）** 双发
- **多 bond**：一份程序 + 一张 map，按 `(bond ifindex, slot)` 键控，任意数量、任意命名的 bond 互不串扰
- **VLAN 零配置**：vlan 子接口（`bondX.N`）的 ARP/NDP 走到 bond 层时 tag 在 skb 元数据里，克隆自动携带
- **非 ARP/NDP 流量零影响**：业务流量仍走 bonding 原生哈希，每包开销只有十几条指令的协议判断
- **安全退化**：程序未挂载/表未配置时精确退化为内核默认行为，永不黑洞；运行时挂载、`arpfanout-remove` 一键回滚
- **无 CO-RE 依赖**：程序只解析 RFC 定义的协议字段，一个预编译 `.o` 跨内核版本加载
- **生产运行模型**：systemd oneshot（开机自动跑一次 + bond 变化后手动 `systemctl restart arpfanout` 收敛）；常驻 `watch` 模式可选

## 仓库内容

| 文件 | 说明 |
|---|---|
| `src/arpfanout.bpf.c` | eBPF 程序源码（tc SCHED_CLS，~130 行） |
| `src/arpfanout.bpf.o` | 预编译对象（x86_64，无 CO-RE 依赖；非 x86_64 装 clang 现场编译） |
| `src/arpfanout` | 用户态管理脚本（`sync`/`boot`/`watch` 三模式） |
| `src/arpfanout.service` | systemd 单元（oneshot + network-online） |
| `src/arpfanout.env` | 配置模板（白名单/等待时长等） |
| `src/arpfanout-remove` | 紧急回滚（秒级恢复内核默认，文件保留） |
| `src/arpfanout-uninstall` | 彻底卸载 |
| `dist/install.sh` | 幂等安装器（重复执行=干净升级，自动装 tc/bpftool） |
| `dist/check.sh` | 部署前 30 秒兼容性检查（实测 clsact 挂载 + BPF 加载） |
| `dist/deploy_hosts.sh` | 跳板机批量部署（scp→check→install→test 逐台汇总） |
| `dist/test_v6.sh` | 一键双发验证（DAD/ping/ndisc6 三路触发 + 双口自动比对） |
| `dist/test_10bonds.sh` | 多 bond 压测（10 bond 逐个双发验证 + 串扰断言） |

源码目录结构与 tarball 一一对应；发布 tarball 由 `dist/mkdist.sh` 生成。

## 快速开始

```bash
# 1. 解压(Release 附件或 git clone 后 mkdist), 目标机 root:
bash check.sh          # 30 秒兼容性检查: 全 [ OK ] 再装
bash install.sh        # 安装 + 开机自启 + 冒烟(幂等)
bash test_v6.sh        # IPv6/NDP 双发验证(输出 PASS/FAIL)

# 2. 验证 IPv4 双发(两窗口分别看成员口, 应看到相同帧):
tcpdump -i <成员口1> -en 'arp and ether src <bond MAC>' &
tcpdump -i <成员口2> -en 'arp and ether src <bond MAC>' &
ip neigh del <网关> dev <bond接口>; ping -c 2 <网关>

# 3. bond 变更(重建/增删成员)后手动收敛:
systemctl restart arpfanout
```

## 运行模型与配置

| 时机 | 行为 |
|---|---|
| 开机 | systemd oneshot 自动跑一次（最多等 `ARP_FANOUT_BOOT_WAIT` 秒让网络配置把 bond 建好），完成后退出，**零常驻进程** |
| bond 变化 | `systemctl restart arpfanout`（幂等；等效 `arpfanout sync`） |
| 需要无人值守 | 切到 `watch` 模式（service 改为 `ExecStart=/usr/local/sbin/arpfanout watch`）：netlink 事件 + 轮询双通道自动跟随 |

配置 `/etc/default/arpfanout`：

- `ARP_FANOUT_BONDS=""` —— 空=跟随所有 bond；或白名单如 `"bond0 bond2"`
- `ARP_FANOUT_BOOT_WAIT=30` —— 开机等待 bond 出现的最长秒数
- `ARP_FANOUT_POLL=5` —— 仅 watch 模式使用的轮询间隔

## 兼容性

- **硬性条件**：Linux 内核 ≥ 4.5（clsact）+ root；建议 4.14+ LTS
- **架构**：x86_64 直接用预编译对象；ARM64 等装 clang 后 `install.sh` 自动现场编译
- **发行版**：Ubuntu/Debian/CentOS/Rocky/openEuler/麒麟等均可（tc 包名：Debian 系 `iproute2`，RHEL 系 `iproute-tc`）
- **已实测**：Ubuntu 22.04（内核 5.15）、openEuler 24.03（内核 6.6）
- 拿不准的机器直接跑 `check.sh`，它会对 clsact 挂载和 BPF 对象加载做真实验证

**资源占用**：eBPF 程序常驻内核内存约 8KB（程序 + map），oneshot 模型零常驻用户态进程；
非 ARP/NDP 流量的每包开销为纳秒级协议判断。唯一"占用"是每个 bond 的 tc egress 挂载位
（一条 `pref 49152` filter）——若机器上有其他组件管理 bond 的 tc 挂载（如部分 CNI），先评估冲突。

## 实现原理

内核发包路径中，tc egress 钩子位于"协议栈已把包交给 bond 之后、bonding 驱动选成员口
**之前**"。程序在这里：

1. 解析帧：非 ARP/NDP → `TC_ACT_OK` 原样放行（业务流量零影响）
2. 命中 ARP（0x0806）或 NDP（ICMPv6 133–136）→ 以 `{bond ifindex, slot}` 查 `slave_tbl` map
3. 对每个成员口 `bpf_clone_redirect()`（skb_clone 后直接注入该成员口发送队列，携带 VLAN 元数据）
4. 全部克隆后 `TC_ACT_SHOT` 丢弃原包（防止 bonding 哈希再发第三份）
5. 查不到表 → `TC_ACT_OK` 放行（安全兜底，永不黑洞）

用户态 `arpfanout sync` 负责"表与现实一致"：扫 sysfs 发现 bond → 给缺挂载的 bond 补
clsact+filter → 按当前成员维护 map 表项（多删少补）。

> **适用前提**：仅用于 leaf 真正独立的去堆叠环境。若环境仍存在堆叠/MLAG，同一 MAC 从两个
> 聚合口出现会触发交换机 MAC 漂移告警——有堆叠就不需要本方案。

## FAQ / 已知坑（tcpdump 观测）

**Q：`tcpdump -i any` 里看不到 `bond0 Out` 行，成员口出现成对的 `Out` 行——正常吗？**

正常，这正是双发生效的表现。eBPF 在 bond 的 tc egress 截获原包并丢弃（`TC_ACT_SHOT`），克隆通过
`bpf_clone_redirect` 直接注入各成员口层，原包不再经过 bond 驱动的发射点，所以 `-i any` 下没有
`bond0 Out` 行；`en0`/`en1` 各一行、微秒级同刻、内容一致，就是双发的标准签名。

**Q：`tcpdump -i any` 抓成员口出现 `ARP, Unknown Hardware (2214) ... Unknown Protocol (0x0000) (len 1)` 乱码——线上帧坏了吗？**

没有。部分内核/驱动/libpcap 组合下，`-i any`（SLL2 cooked 模式）的协议解析会错位 4 字节，
tcpdump 把捕获头尾部的字节当作 ARP 头读出乱码。**判别指纹**：乱码里 "Unknown Hardware (N)"
的字节值等于**帧发送方 MAC 的最后两字节**——出向（本机双发克隆）= 本机 bond MAC 的尾巴，
入向（网关请求）= 网关 MAC（如 `00:00:00:00:00:01`）的尾巴 `00 01`。由于乱码字节来自捕获
视图而非线路，线上帧本身是正确的（具体接口原始模式抓包可复核）。

**入向包在 `-i any` 下会呈现三层 tap**：同一包 `enX In`、`bond0 In`（均乱码、length=46+4）、
`bond0.2101 In`（干净解码、length=46）——VLAN tag 在成员口/bond 层还在数据里、到 vlan 子口
层被剥到元数据。看入向真相直接读 vlan 子口那行即可。

**判别/验证一律用具体成员口 + 原始模式，不要用 `-i any`：**

```bash
tcpdump -i <成员口> -en -c 4 arp
# 健康长相：
# 94:a6:..:08:a6 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q (0x8100), length 46:
#   vlan 2101, p 0, ethertype ARP (0x0806), Request who-has ... length 28
```

另注：任播网关（全 0 类虚 MAC）对同一目标的询问可能从两个成员口先后到达（两张 leaf 独立解析），
本机对每个询问产生一个应答、每个应答又被双发——成员口上看到"两问两答×双份"属于正常现象。

## License

GPL-2.0（与 Linux 内核 BPF helper 使用许可一致）
