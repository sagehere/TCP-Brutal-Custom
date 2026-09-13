#ifndef BRUTAL_H
#define BRUTAL_H

#include <linux/version.h>
#include <linux/gfp.h>
#include <linux/refcount.h>
#include <linux/rhashtable.h>
#include <linux/seqlock.h>
#include <linux/spinlock.h>
#include <net/tcp.h>

struct seq_file;
struct proc_ops;

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#error "TCP Brutal requires Linux 5.10 or later"
#endif

/* procfs private-data helper was renamed in Linux 5.17. */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 17, 0)
#define pde_data(inode) PDE_DATA(inode)
#endif

#define BRUTAL_VERSION_MAJOR 2
#define BRUTAL_VERSION_MINOR 3
#define BRUTAL_VERSION_PATCH 0
#define BRUTAL_VERSION ((BRUTAL_VERSION_MAJOR << 16) | (BRUTAL_VERSION_MINOR << 8) | BRUTAL_VERSION_PATCH)

#define TCP_BRUTAL_PARAMS 23301  // setsockopt/getsockopt: struct brutal_params
#define TCP_BRUTAL_VERSION 23302 // getsockopt: u32 (major << 16 | minor << 8 | patch)

#define INIT_PACING_RATE 125000 // 1 Mbps
#define INIT_CWND_GAIN 20

#define MIN_PACING_RATE 62500           // 500 Kbps
#define MAX_PACING_RATE 125000000000ULL // 1 Tbps; keeps all the u64 arithmetic in range
#define MIN_CWND_GAIN 5
#define MAX_CWND_GAIN 80
#define MIN_CWND 4

#define PKT_INFO_SLOTS 4
#define BRUTAL_FALLBACK_PACERS 16

struct brutal_pkt_info
{
    u32 sec;
    u32 acked;
    u32 losses;
};

/* Peer tables are scoped by destination rule and network namespace. */
struct brutal_peer_key
{
    u8 family;
    u8 padding[3];
    union
    {
        __be32 v4;
        struct in6_addr v6;
    };
};

// Sockets sharing one total rate.
// Before each transmit, a member reserves the next burst on the group's
// virtual clock (next_ns) and sets its own EDT (tcp_wstamp_ns) to that slot,
// so the group never exceeds rate while any single active member can use all of it.
struct brutal_group
{
    struct hlist_node node;
    refcount_t refcnt;
    spinlock_t lock; // protects next_ns
    u64 id;          // application group id, or rule id for a rule's group
    kuid_t uid;
    struct net *net;

    /* Configuration is independent from the pacing lock. */
    spinlock_t config_lock;
    seqcount_t config_seq;
    u64 rate;
    u32 cwnd_gain;
    atomic_t generation;
    u8 locked; // rule group: applications may not change the params

    atomic_t members;
    atomic64_t sent_bytes;
    void *rule_stats;
    u64 next_ns;

    // A per-IP child owns a reference to its rule group. It has its own clock,
    // but inherits rate, gain, and lock from that parent.
    struct brutal_group *parent;
    struct brutal_group **fallbacks;
    struct rhash_head perip_node;
    struct rcu_head rcu;
    struct brutal_peer_key peer_key;
    atomic_t ip_groups;
    u8 fallback;
};

// Per-socket state, lives in icsk_ca_priv
struct brutal
{
    u64 rate;
    u64 effective_rate;
    struct brutal_group *group; // NULL = per-socket rate (v1 behavior)

    u64 resv_start_ns;
    u64 resv_bytes_sent; // tp->bytes_sent when reserved
    u32 resv_bytes;      // 0: no outstanding reservation
    u32 resv_duration_ns;
    u16 last_update_tick;
    u16 seen_generation;
    u8 cwnd_gain;
    u8 ack_rate; // percent, from the last rate update
    u16 padding;

    struct brutal_pkt_info slots[PKT_INFO_SLOTS];
};

struct brutal_params
{
    u64 rate;      // Send rate in bytes per second
    u32 cwnd_gain; // CWND gain in tenths (10=1.0)
    u64 group_id;  // 0 = per-socket rate; the 12-byte v1 struct is also accepted
} __packed;

#define BRUTAL_PARAMS_V1_SIZE offsetof(struct brutal_params, group_id)

// brutal_cc.c: the congestion control
extern struct tcp_congestion_ops tcp_brutal_ops;
void brutal_update_rate(struct sock *sk);

// brutal_sockopt.c: groups and the application interface
struct brutal_group *brutal_group_alloc(u64 id, gfp_t gfp);
void brutal_group_put(struct brutal_group *g);
void brutal_group_join(struct brutal *brutal, struct brutal_group *g);
void brutal_group_leave(struct sock *sk);
void brutal_settle_reservation(struct sock *sk);
struct brutal_group *brutal_perip_group_get(struct sock *sk, struct brutal_group *parent);
u64 brutal_group_rate(struct brutal_group *g);
u32 brutal_group_cwnd_gain(struct brutal_group *g);
u16 brutal_group_generation(struct brutal_group *g);
bool brutal_group_locked(struct brutal_group *g);
void brutal_group_get_config(struct brutal_group *g, u64 *rate, u32 *gain,
                             bool *locked, u16 *generation);
void brutal_group_set_config(struct brutal_group *g, u64 rate, u32 gain, bool locked);
int brutal_group_enable_rule_stats(struct brutal_group *g, bool perip);
void brutal_group_release_fallbacks(struct brutal_group *g);
void brutal_group_account_sent(struct brutal_group *g, u64 bytes);
u64 brutal_group_sent(struct brutal_group *g);
int brutal_group_dump_peers(struct seq_file *m, struct brutal_group *parent);
int brutal_sockopt_init(void);
void brutal_sockopt_exit(void);
void brutal_sockopt_install(struct sock *sk);
void brutal_sockopt_uninstall(struct sock *sk);
void brutal_net_peer_alloc_failed(struct net *net);
void brutal_net_peer_insert_failed(struct net *net);
void brutal_net_peer_fallback(struct net *net);
void brutal_net_peer_added(struct net *net);
void brutal_net_peer_removed(struct net *net);

// brutal_rules.c: destination rules and /proc/net/tcp_brutal/rules
void brutal_apply_rule(struct sock *sk, struct brutal *brutal);
int brutal_rules_init(void);
void brutal_rules_exit(void);

#endif // BRUTAL_H
