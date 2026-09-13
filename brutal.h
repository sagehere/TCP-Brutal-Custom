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

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 17, 0)
#define pde_data(inode) PDE_DATA(inode)
#endif

#define BRUTAL_VERSION_MAJOR 2
#define BRUTAL_VERSION_MINOR 3
#define BRUTAL_VERSION_PATCH 0
#define BRUTAL_VERSION ((BRUTAL_VERSION_MAJOR << 16) | (BRUTAL_VERSION_MINOR << 8) | BRUTAL_VERSION_PATCH)

#define TCP_BRUTAL_PARAMS 23301
#define TCP_BRUTAL_VERSION 23302

#define INIT_PACING_RATE 125000
#define INIT_CWND_GAIN 20

#define MIN_PACING_RATE 62500
#define MAX_PACING_RATE 125000000000ULL
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

struct brutal_app_key
{
    kuid_t uid;
    u32 padding;
    u64 id;
};

struct brutal_group;

enum brutal_pacer_type
{
    BRUTAL_PACER_GROUP = 0,
    BRUTAL_PACER_PEER,
    BRUTAL_PACER_FALLBACK,
};

struct brutal_rate_cfg
{
    spinlock_t lock;
    seqcount_t seq;
    u64 rate;
    u32 cwnd_gain;
    atomic_t generation;
    u8 locked;
};

/* Hot shared state used by the transmit path. */
struct brutal_pacer
{
    refcount_t refcnt;
    spinlock_t lock; // protects next_ns
    atomic_t members;
    atomic64_t sent_bytes;
    u64 next_ns;
    struct brutal_group *parent; // non-NULL for per-IP and fallback pacers
    u8 type;
};

/* Lifetime/configuration owner for application and destination-rule groups. */
struct brutal_group
{
    struct brutal_pacer pacer;
    struct brutal_rate_cfg cfg;
    u64 id;
    struct net *net; // non-NULL only for application groups

    void *rule_stats;
    struct brutal_pacer **fallbacks;
    atomic_t ip_groups;

    struct rhash_head app_node;
    struct rcu_head rcu;
    struct brutal_app_key app_key;
};

/* Lightweight per-IP object; it does not carry rule/app configuration fields. */
struct brutal_peer
{
    struct brutal_pacer pacer;
    struct rhash_head node;
    struct rcu_head rcu;
    struct brutal_peer_key key;
    struct net *net;
};

struct brutal
{
    u64 rate;
    u64 effective_rate;
    struct brutal_pacer *group; // NULL = per-socket rate

    u64 resv_start_ns;
    u64 resv_bytes_sent;
    u32 resv_bytes;
    u32 resv_duration_ns;
    u16 last_update_tick;
    u16 seen_generation;
    u8 cwnd_gain;
    u8 ack_rate;
    u16 padding;

    struct brutal_pkt_info slots[PKT_INFO_SLOTS];
};

struct brutal_params
{
    u64 rate;
    u32 cwnd_gain;
    u64 group_id;
} __packed;

#define BRUTAL_PARAMS_V1_SIZE offsetof(struct brutal_params, group_id)

extern struct tcp_congestion_ops tcp_brutal_ops;
void brutal_update_rate(struct sock *sk);

struct brutal_group *brutal_group_alloc(u64 id, gfp_t gfp);
void brutal_group_put(struct brutal_group *g);
void brutal_pacer_get(struct brutal_pacer *p);
void brutal_pacer_put(struct brutal_pacer *p);
u64 brutal_pacer_id(struct brutal_pacer *p);
void brutal_group_join(struct brutal *brutal, struct brutal_pacer *p);
void brutal_group_leave(struct sock *sk);
void brutal_settle_reservation(struct sock *sk);
struct brutal_pacer *brutal_perip_group_get(struct sock *sk, struct brutal_group *parent);
u64 brutal_group_rate(struct brutal_pacer *p);
u32 brutal_group_cwnd_gain(struct brutal_pacer *p);
u16 brutal_group_generation(struct brutal_pacer *p);
bool brutal_group_locked(struct brutal_pacer *p);
void brutal_group_get_config(struct brutal_pacer *p, u64 *rate, u32 *gain,
                             bool *locked, u16 *generation);
void brutal_group_set_config(struct brutal_pacer *p, u64 rate, u32 gain,
                             bool locked);
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

struct brutal_group *brutal_app_group_get(struct sock *sk, u64 id);
void brutal_app_group_remove(struct brutal_group *g);
void brutal_apply_rule(struct sock *sk, struct brutal *brutal);
int brutal_rules_init(void);
void brutal_rules_exit(void);

#endif
