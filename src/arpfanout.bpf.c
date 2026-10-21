// arpfanout.bpf.c — 802.3ad bond 成员口 ARP/NDP 双发(去堆叠双上联场景)
//
// 挂载点: bond 主设备 clsact egress(不要挂在 vlan 子设备上: 那里 skb
// 尚无 vlan 信息, 克隆出去的帧没有 tag)。
//
// 行为:
//   - 双发对象: IPv4 ARP(0x0806) 与 IPv6 NDP(ICMPv6 type 133-136: RS/RA/NS/NA)
//   - 非 ARP/NDP 流量一律 TC_ACT_OK, 业务流量仍由 bonding 做 hash,零影响
//   - 命中的帧按表克隆到该 bond 的每个成员口 egress (bpf_clone_redirect)
//   - 克隆成功后吞掉原包(否则 hash 选中的口会重复发一份)
//   - 查不到任何成员配置时放行原包,避免配置缺失时 ARP 被黑洞(部署安全序)
//
// VLAN: vlan 子接口(bondX.N)的 ARP/NDP 走到 bond 层时, tag 在 skb 元数据
// (vlan_tci)里, 帧字节里 h_proto 仍是 0x0806/0x86dd, 一次匹配覆盖所有 VLAN;
// clone_redirect 会连元数据一起克隆, 由成员口(或网卡 offload)补上 tag。
// inline 802.1Q(0x8100) 内层载荷的场景(桥/租户流量)也做了匹配。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ipv6.h>
#include <linux/icmpv6.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* 每 bond 成员槽位上限(循环展开次数, 验证器要求编译期常量);
 * map 容量按 "MAX_SLAVES × bond 数" 留 3 倍余量: 16 × 10 bond = 160 → 512 表项 */
#define MAX_SLAVES 16

struct bond_key {
    __u32 bond;   /* bond ifindex —— tc egress 处 skb->ifindex 即 bond 的 ifindex */
    __u32 slot;   /* 成员口槽位 */
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 512);
    __type(key, struct bond_key);
    __type(value, __u32);      /* 成员口 ifindex */
} slave_tbl SEC(".maps");

/* uapi 头文件里没有完整定义, 本地补一个(内核 include/linux/if_vlan.h 同构) */
struct vlan_hdr {
    __be16 h_vlan_TCI;
    __be16 h_vlan_encapsulated_proto;
};

/* 返回跳过(可选 inline vlan 头后的)载荷起始指针, 非 IP/ARP 载荷返回 0 */
static __always_inline void *l3_ptr(struct __sk_buff *skb, __be16 *inner_proto)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    if (data + sizeof(*eth) > data_end)
        return 0;
    *inner_proto = eth->h_proto;
    if (eth->h_proto == bpf_htons(ETH_P_8021Q)) {
        struct vlan_hdr *vh = data + sizeof(*eth);
        if ((void *)vh + sizeof(*vh) > data_end)
            return 0;
        *inner_proto = vh->h_vlan_encapsulated_proto;
        return (void *)vh + sizeof(*vh);
    }
    return (void *)eth + sizeof(*eth);
}

/* IPv4 ARP? (vlan tag 任意: 元数据形态帧字节就是 0x0806) */
static __always_inline int is_arp(struct __sk_buff *skb)
{
    __be16 p;
    l3_ptr(skb, &p);
    return p == bpf_htons(ETH_P_ARP);
}

/* IPv6 NDP(ICMPv6 133-136: RS/RA/NS/NA)? */
static __always_inline int is_nd(struct __sk_buff *skb)
{
    __be16 p;
    void *l3 = l3_ptr(skb, &p);

    if (p != bpf_htons(ETH_P_IPV6))
        return 0;
    if (!l3 || l3 + sizeof(struct ipv6hdr) + sizeof(struct icmp6hdr)
              > (void *)(long)skb->data_end)
        return 0;
    struct ipv6hdr *ip6 = l3;
    if (ip6->nexthdr != IPPROTO_ICMPV6)
        return 0;
    struct icmp6hdr *icmp6 = l3 + sizeof(*ip6);
    __u8 t = icmp6->icmp6_type;
    return t >= 133 && t <= 136;
}

SEC("classifier")
int arp_fanout(struct __sk_buff *skb)
{
    struct bond_key k = {};
    int sent = 0;

    if (!is_arp(skb) && !is_nd(skb))
        return TC_ACT_OK;

    k.bond = skb->ifindex;

    #pragma unroll
    for (int i = 0; i < MAX_SLAVES; i++) {
        __u32 *slave;
        k.slot = (__u32)i;
        slave = bpf_map_lookup_elem(&slave_tbl, &k);
        if (!slave)
            break;
        if (*slave && *slave != skb->ifindex) {
            bpf_clone_redirect(skb, *slave, 0);
            sent++;
        }
    }
    return sent ? TC_ACT_SHOT : TC_ACT_OK;
}

char LICENSE[] SEC("license") = "GPL";
