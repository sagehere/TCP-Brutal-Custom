// Groups and the application interface: TCP_BRUTAL_PARAMS / TCP_BRUTAL_VERSION
#include <linux/hashtable.h>
#include <linux/jhash.h>
#include <linux/mempool.h>
#include <linux/percpu_counter.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include "brutal.h"

#if IS_ENABLED(CONFIG_IPV6)
#include <net/transp_v6.h>
#endif
#if IS_ENABLED(CONFIG_TLS)
#include <net/tls.h>
#endif

static DEFINE_HASHTABLE(brutal_groups, 8);
static DEFINE_SPINLOCK(brutal_groups_lock);
static struct rhashtable brutal_perip_groups;
static struct kmem_cache *brutal_peer_cache;
static mempool_t *brutal_peer_pool;
static struct workqueue_struct *brutal_free_wq;

struct brutal_rule_stats
{
    struct percpu_counter sent_bytes;
    struct work_struct destroy_work;
    struct brutal_group *group;
};
static const struct rhashtable_params brutal_perip_params = {
    .head_offset = offsetof(struct brutal_group, perip_node),
    .key_offset = offsetof(struct brutal_group, peer_key),
    .key_len = sizeof(struct brutal_peer_key),
    .automatic_shrinking = true,
};

static struct proto tcp_prot_override __ro_after_init;
#ifdef _TRANSP_V6_H
static struct proto tcpv6_prot_override __ro_after_init;
#endif

static void brutal_group_init(struct brutal_group *g, u64 id)
{
    refcount_set(&g->refcnt, 1);
    spin_lock_init(&g->lock);
    atomic_set(&g->members, 0);
    atomic_set(&g->ip_groups, 0);
    atomic_set(&g->generation, 0);
    atomic64_set(&g->sent_bytes, 0);
    g->id = id;
    g->rate = INIT_PACING_RATE;
    g->cwnd_gain = INIT_CWND_GAIN;
}

struct brutal_group *brutal_group_alloc(u64 id, gfp_t gfp)
{
    struct brutal_group *g = kzalloc(sizeof(*g), gfp);

    if (!g)
        return NULL;
    brutal_group_init(g, id);
    return g;
}

static struct brutal_group *brutal_peer_alloc(u64 id)
{
    struct brutal_group *g = mempool_alloc(brutal_peer_pool, GFP_ATOMIC);

    if (!g)
        return NULL;
    memset(g, 0, sizeof(*g));
    brutal_group_init(g, id);
    return g;
}

static struct brutal_group *brutal_group_parent(struct brutal_group *g)
{
    return g->parent ? g->parent : g;
}

u64 brutal_group_rate(struct brutal_group *g)
{
    u64 rate;

    brutal_group_get_config(g, &rate, NULL, NULL, NULL);
    return rate;
}

u32 brutal_group_cwnd_gain(struct brutal_group *g)
{
    u32 gain;

    brutal_group_get_config(g, NULL, &gain, NULL, NULL);
    return gain;
}

int brutal_group_enable_rule_stats(struct brutal_group *g, bool perip)
{
    struct brutal_rule_stats *stats = kzalloc(sizeof(*stats), GFP_KERNEL);
    struct brutal_group **fallbacks = NULL;
    int i;
    int ret;

    if (!stats)
        return -ENOMEM;
    ret = percpu_counter_init(&stats->sent_bytes, 0, GFP_KERNEL);
    if (ret)
    {
        kfree(stats);
        return ret;
    }
    if (perip)
    {
        fallbacks = kcalloc(BRUTAL_FALLBACK_PACERS, sizeof(*fallbacks),
                            GFP_KERNEL);
        if (!fallbacks)
            goto fail;
        for (i = 0; i < BRUTAL_FALLBACK_PACERS; i++)
        {
            fallbacks[i] = brutal_group_alloc(g->id, GFP_KERNEL);
            if (!fallbacks[i])
                goto fail;
            fallbacks[i]->parent = g;
            fallbacks[i]->fallback = true;
            refcount_inc(&g->refcnt);
        }
    }
    stats->group = g;
    g->fallbacks = fallbacks;
    g->rule_stats = stats;
    return 0;

fail:
    for (i = 0; i < BRUTAL_FALLBACK_PACERS; i++)
    {
        if (!fallbacks || !fallbacks[i])
            break;
        kfree(fallbacks[i]);
        refcount_dec(&g->refcnt);
    }
    kfree(fallbacks);
    percpu_counter_destroy(&stats->sent_bytes);
    kfree(stats);
    return -ENOMEM;
}

void brutal_group_account_sent(struct brutal_group *g, u64 bytes)
{
    struct brutal_rule_stats *stats = READ_ONCE(g->rule_stats);

    if (stats)
        percpu_counter_add(&stats->sent_bytes, bytes);
    else
        atomic64_add(bytes, &g->sent_bytes);
}

u64 brutal_group_sent(struct brutal_group *g)
{
    struct brutal_rule_stats *stats = READ_ONCE(g->rule_stats);

    return stats ? percpu_counter_sum_positive(&stats->sent_bytes) : atomic64_read(&g->sent_bytes);
}

u16 brutal_group_generation(struct brutal_group *g)
{
    struct brutal_group *parent = brutal_group_parent(g);
    u16 generation = (u16)atomic_read(&parent->generation);

    smp_rmb();
    return generation;
}

void brutal_group_get_config(struct brutal_group *g, u64 *rate, u32 *gain,
                             bool *locked, u16 *generation)
{
    struct brutal_group *parent = brutal_group_parent(g);
    u16 before, after;

    do
    {
        before = (u16)atomic_read(&parent->generation);
        smp_rmb();
        if (rate)
            *rate = READ_ONCE(parent->rate);
        if (gain)
            *gain = READ_ONCE(parent->cwnd_gain);
        if (locked)
            *locked = READ_ONCE(parent->locked);
        smp_rmb();
        after = (u16)atomic_read(&parent->generation);
    } while (before != after);
    if (generation)
        *generation = after;
}

void brutal_group_set_config(struct brutal_group *g, u64 rate, u32 gain, bool locked)
{
    g = brutal_group_parent(g);
    WRITE_ONCE(g->rate, rate);
    WRITE_ONCE(g->cwnd_gain, gain);
    WRITE_ONCE(g->locked, locked);
    smp_wmb();
    atomic_inc(&g->generation);
}

bool brutal_group_locked(struct brutal_group *g)
{
    bool locked;

    brutal_group_get_config(g, NULL, NULL, &locked, NULL);
    return locked;
}

struct brutal_peer_seq
{
    struct rhashtable_iter iter;
    struct net *net;
};

static struct brutal_group *brutal_peer_seq_next(struct brutal_peer_seq *ctx)
{
    struct brutal_group *g;

    for (;;)
    {
        g = rhashtable_walk_next(&ctx->iter);
        if (IS_ERR(g))
        {
            if (PTR_ERR(g) == -EAGAIN)
                continue;
            return NULL;
        }
        if (!g)
            return NULL;
        if (g->net == ctx->net && atomic_read(&g->members))
            return g;
    }
}

static void *brutal_peers_seq_start(struct seq_file *m, loff_t *pos)
{
    struct brutal_peer_seq *ctx = m->private;
    struct brutal_group *g = NULL;
    loff_t i;

    rhashtable_walk_enter(&brutal_perip_groups, &ctx->iter);
    rhashtable_walk_start(&ctx->iter);
    for (i = 0; i <= *pos; i++)
    {
        g = brutal_peer_seq_next(ctx);
        if (!g)
            break;
    }
    return g;
}

static void *brutal_peers_seq_next(struct seq_file *m, void *v, loff_t *pos)
{
    struct brutal_peer_seq *ctx = m->private;

    ++*pos;
    return brutal_peer_seq_next(ctx);
}

static void brutal_peers_seq_stop(struct seq_file *m, void *v)
{
    struct brutal_peer_seq *ctx = m->private;

    rhashtable_walk_stop(&ctx->iter);
    rhashtable_walk_exit(&ctx->iter);
}

static int brutal_peers_seq_show(struct seq_file *m, void *v)
{
    struct brutal_group *g = v;
    u64 rate;
    u32 gain;

    brutal_group_get_config(g, &rate, &gain, NULL, NULL);
    if (g->peer_key.family == AF_INET)
        seq_printf(m, "ip=%pI4 family=4", &g->peer_key.v4);
    else
        seq_printf(m, "ip=%pI6c family=6", &g->peer_key.v6);
    seq_printf(m, " rule=%llu rate=%llu gain=%u members=%u sent=%llu\n",
               g->parent->id, rate, gain, atomic_read(&g->members),
               atomic64_read(&g->sent_bytes));
    return 0;
}

static const struct seq_operations brutal_peers_seq_ops = {
    .start = brutal_peers_seq_start,
    .next = brutal_peers_seq_next,
    .stop = brutal_peers_seq_stop,
    .show = brutal_peers_seq_show,
};

static int brutal_peers_open(struct inode *inode, struct file *file)
{
    struct seq_file *m;
    int ret = seq_open_private(file, &brutal_peers_seq_ops,
                               sizeof(struct brutal_peer_seq));

    if (ret)
        return ret;
    m = file->private_data;
    ((struct brutal_peer_seq *)m->private)->net = pde_data(inode);
    return 0;
}

const struct proc_ops brutal_peers_proc_ops = {
    .proc_open = brutal_peers_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = seq_release_private,
};

// Application group keyed by id, uid and netns; created if missing
static struct brutal_group *brutal_group_get(struct sock *sk, u64 id)
{
    struct brutal_group *g, *ng = brutal_group_alloc(id, GFP_KERNEL);

    spin_lock_bh(&brutal_groups_lock);
    hash_for_each_possible(brutal_groups, g, node, id)
    {
        if (g->id == id && uid_eq(g->uid, sk->sk_uid) && g->net == sock_net(sk) &&
            refcount_inc_not_zero(&g->refcnt))
        {
            spin_unlock_bh(&brutal_groups_lock);
            kfree(ng);
            return g;
        }
    }
    if (ng)
    {
        ng->uid = sk->sk_uid;
        ng->net = sock_net(sk);
        hash_add(brutal_groups, &ng->node, id);
    }
    spin_unlock_bh(&brutal_groups_lock);
    return ng;
}

static void brutal_perip_key(const struct sock *sk, struct brutal_group *parent,
                             struct brutal_peer_key *key)
{
    memset(key, 0, sizeof(*key));
    key->parent = parent;
    key->net = sock_net(sk);
#if IS_ENABLED(CONFIG_IPV6)
    if (sk->sk_family == AF_INET6 && !ipv6_addr_v4mapped(&sk->sk_v6_daddr))
    {
        key->family = AF_INET6;
        key->v6 = sk->sk_v6_daddr;
        return;
    }
#endif
    key->family = AF_INET;
    key->v4 = sk->sk_daddr;
}

static struct brutal_group *brutal_fallback_group_get(
    const struct brutal_peer_key *key, struct brutal_group *parent)
{
    struct brutal_group **fallbacks = READ_ONCE(parent->fallbacks);
    struct brutal_group *g;
    u32 hash;

    if (!fallbacks)
        return NULL;
    if (key->family == AF_INET)
        hash = jhash_1word((__force u32)key->v4, (u32)parent->id);
    else
        hash = jhash(key->v6.s6_addr, sizeof(key->v6.s6_addr),
                     (u32)parent->id);
    g = fallbacks[hash & (BRUTAL_FALLBACK_PACERS - 1)];
    refcount_inc(&g->refcnt);
    brutal_group_put(parent);
    brutal_net_peer_fallback(key->net);
    return g;
}

// Takes the caller's parent reference on success or allocation failure.
struct brutal_group *brutal_perip_group_get(struct sock *sk, struct brutal_group *parent)
{
    struct brutal_group *g, *ng;
    struct brutal_peer_key key;

    brutal_perip_key(sk, parent, &key);
    rcu_read_lock();
    g = rhashtable_lookup_fast(&brutal_perip_groups, &key,
                               brutal_perip_params);
    if (g && !refcount_inc_not_zero(&g->refcnt))
        g = NULL;
    rcu_read_unlock();
    if (g)
    {
        brutal_group_put(parent);
        return g;
    }

    ng = brutal_peer_alloc(parent->id);
    if (!ng)
    {
        brutal_net_peer_alloc_failed(sock_net(sk));
        return brutal_fallback_group_get(&key, parent);
    }
    ng->parent = parent;
    ng->net = sock_net(sk);
    ng->peer_key = key;

    g = rhashtable_lookup_get_insert_fast(&brutal_perip_groups,
                                          &ng->perip_node,
                                          brutal_perip_params);
    if (IS_ERR(g))
    {
        brutal_net_peer_insert_failed(sock_net(sk));
        mempool_free(ng, brutal_peer_pool);
        return brutal_fallback_group_get(&key, parent);
    }
    if (g)
    {
        if (refcount_inc_not_zero(&g->refcnt))
        {
            brutal_group_put(parent);
            mempool_free(ng, brutal_peer_pool);
            return g;
        }
        mempool_free(ng, brutal_peer_pool);
        return brutal_fallback_group_get(&key, parent);
    }
    atomic_inc(&parent->ip_groups);
    brutal_net_peer_added(sock_net(sk));
    return ng;
}

static void brutal_peer_free_rcu(struct rcu_head *rcu)
{
    struct brutal_group *g = container_of(rcu, struct brutal_group, rcu);

    brutal_group_put(g->parent);
    mempool_free(g, brutal_peer_pool);
}

static void brutal_rule_group_free_work(struct work_struct *work)
{
    struct brutal_rule_stats *stats =
        container_of(work, struct brutal_rule_stats, destroy_work);

    percpu_counter_destroy(&stats->sent_bytes);
    kfree(stats->group);
    kfree(stats);
}

void brutal_group_put(struct brutal_group *g)
{
    if (g->parent)
    {
        struct brutal_group *parent = g->parent;

        if (!refcount_dec_and_test(&g->refcnt))
            return;
        if (g->fallback)
        {
            brutal_group_put(parent);
            kfree(g);
            return;
        }
        rhashtable_remove_fast(&brutal_perip_groups, &g->perip_node,
                               brutal_perip_params);
        atomic_dec(&parent->ip_groups);
        brutal_net_peer_removed(g->net);
        call_rcu(&g->rcu, brutal_peer_free_rcu);
        return;
    }
    if (!refcount_dec_and_test(&g->refcnt))
        return;
    spin_lock_bh(&brutal_groups_lock);
    hash_del(&g->node); // no-op for a rule's group, which is never hashed
    spin_unlock_bh(&brutal_groups_lock);
    if (g->rule_stats)
    {
        struct brutal_rule_stats *stats = g->rule_stats;

        INIT_WORK(&stats->destroy_work, brutal_rule_group_free_work);
        queue_work(brutal_free_wq, &stats->destroy_work);
        return;
    }
    kfree(g);
}

void brutal_group_release_fallbacks(struct brutal_group *g)
{
    struct brutal_group **fallbacks = xchg(&g->fallbacks, NULL);
    int i;

    if (!fallbacks)
        return;
    for (i = 0; i < BRUTAL_FALLBACK_PACERS; i++)
        brutal_group_put(fallbacks[i]);
    kfree(fallbacks);
}

// Takes over the caller's reference on g
void brutal_group_join(struct brutal *brutal, struct brutal_group *g)
{
    brutal->group = g;
    atomic_inc(&g->members);
    if (g->parent)
    {
        atomic_inc(&g->parent->members);
    }
}

void brutal_group_leave(struct sock *sk)
{
    struct brutal *brutal = inet_csk_ca(sk);
    struct brutal_group *g = brutal->group;

    if (!g)
        return;
    brutal_settle_reservation(sk);
    brutal->group = NULL;
    atomic_dec(&g->members);
    if (g->parent)
    {
        atomic_dec(&g->parent->members);
    }
    brutal_group_put(g);
}

static int brutal_set_params(struct sock *sk, sockptr_t optval, unsigned int optlen)
{
    struct brutal *brutal = inet_csk_ca(sk);
    struct brutal_params params = {};

    if (optlen < BRUTAL_PARAMS_V1_SIZE)
        return -EINVAL;
    if (copy_from_sockptr(&params, optval, min_t(unsigned int, optlen, sizeof(params))))
        return -EFAULT;
    if (optlen < sizeof(params))
        params.group_id = 0;

    // Sanity checks
    if (params.rate < MIN_PACING_RATE || params.rate > MAX_PACING_RATE)
        return -EINVAL;
    if (params.cwnd_gain < MIN_CWND_GAIN || params.cwnd_gain > MAX_CWND_GAIN)
        return -EINVAL;

    // The proto-level override runs before the kernel would take the socket
    // lock, and the group pointer must not change under the transmit hook
    lock_sock(sk);
    if (inet_csk(sk)->icsk_ca_ops != &tcp_brutal_ops)
    {
        release_sock(sk); // the socket has been switched to another algorithm
        return -ENOPROTOOPT;
    }
    if (brutal->group && brutal_group_locked(brutal->group))
    {
        release_sock(sk);
        return -EPERM; // governed by a locked destination rule
    }
    if (!params.group_id)
        brutal_group_leave(sk);
    else if (!brutal->group || brutal->group->id != params.group_id)
    {
        struct brutal_group *g = brutal_group_get(sk, params.group_id);
        if (!g)
        {
            release_sock(sk);
            return -ENOMEM;
        }
        brutal_group_leave(sk);
        brutal_group_join(brutal, g);
    }
    if (brutal->group)
    {
        brutal_group_set_config(brutal->group, params.rate, params.cwnd_gain,
                                brutal_group_locked(brutal->group));
    }
    brutal->rate = params.rate;
    brutal->cwnd_gain = params.cwnd_gain;
    brutal_update_rate(sk);
    release_sock(sk);

    return 0;
}

// Returns the params in effect:
// For a group member, the group's rate and cwnd_gain.
// A 12-byte (v1) buffer gets the first two fields.
static int brutal_get_params(struct sock *sk, char __user *optval, int __user *optlen)
{
    struct brutal *brutal = inet_csk_ca(sk);
    struct brutal_params params;
    int len;

    if (get_user(len, optlen))
        return -EFAULT;
    if (len < BRUTAL_PARAMS_V1_SIZE)
        return -EINVAL;
    len = min_t(int, len, sizeof(params));

    lock_sock(sk);
    if (inet_csk(sk)->icsk_ca_ops != &tcp_brutal_ops)
    {
        release_sock(sk);
        return -ENOPROTOOPT;
    }
    if (brutal->group)
    {
        brutal_group_get_config(brutal->group, &params.rate,
                                &params.cwnd_gain, NULL, NULL);
        params.group_id = brutal->group->id;
    }
    else
    {
        params.rate = brutal->rate;
        params.cwnd_gain = brutal->cwnd_gain;
        params.group_id = 0;
    }
    release_sock(sk);

    if (put_user(len, optlen) || copy_to_user(optval, &params, len))
        return -EFAULT;
    return 0;
}

static int brutal_get_version(char __user *optval, int __user *optlen)
{
    u32 version = BRUTAL_VERSION;
    int len;

    if (get_user(len, optlen))
        return -EFAULT;
    if (len < sizeof(version))
        return -EINVAL;
    len = sizeof(version);
    if (put_user(len, optlen) || copy_to_user(optval, &version, len))
        return -EFAULT;
    return 0;
}

static int brutal_tcp_setsockopt(struct sock *sk, int level, int optname, sockptr_t optval, unsigned int optlen)
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_set_params(sk, optval, optlen);
    else
        return tcp_prot.setsockopt(sk, level, optname, optval, optlen);
}

static int brutal_tcp_getsockopt(struct sock *sk, int level, int optname, char __user *optval, int __user *optlen)
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_get_params(sk, optval, optlen);
    else if (level == IPPROTO_TCP && optname == TCP_BRUTAL_VERSION)
        return brutal_get_version(optval, optlen);
    else
        return tcp_prot.getsockopt(sk, level, optname, optval, optlen);
}

#ifdef _TRANSP_V6_H
static int brutal_tcpv6_setsockopt(struct sock *sk, int level, int optname, sockptr_t optval, unsigned int optlen)
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_set_params(sk, optval, optlen);
    else
        return tcpv6_prot.setsockopt(sk, level, optname, optval, optlen);
}

static int brutal_tcpv6_getsockopt(struct sock *sk, int level, int optname, char __user *optval, int __user *optlen)
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_get_params(sk, optval, optlen);
    else if (level == IPPROTO_TCP && optname == TCP_BRUTAL_VERSION)
        return brutal_get_version(optval, optlen);
    else
        return tcpv6_prot.getsockopt(sk, level, optname, optval, optlen);
}
#endif // _TRANSP_V6_H

// Prepare the proto tables that route our sockopts to us
int __init brutal_sockopt_init(void)
{
    int ret;

    brutal_free_wq = alloc_workqueue("tcp_brutal_free",
                                     WQ_UNBOUND | WQ_MEM_RECLAIM, 0);
    if (!brutal_free_wq)
        return -ENOMEM;
    brutal_peer_cache = kmem_cache_create("tcp_brutal_peer",
                                          sizeof(struct brutal_group), 0,
                                          SLAB_HWCACHE_ALIGN, NULL);
    if (!brutal_peer_cache)
    {
        destroy_workqueue(brutal_free_wq);
        return -ENOMEM;
    }
    brutal_peer_pool = mempool_create_slab_pool(32, brutal_peer_cache);
    if (!brutal_peer_pool)
    {
        kmem_cache_destroy(brutal_peer_cache);
        destroy_workqueue(brutal_free_wq);
        return -ENOMEM;
    }
    ret = rhashtable_init(&brutal_perip_groups, &brutal_perip_params);

    if (ret)
    {
        mempool_destroy(brutal_peer_pool);
        kmem_cache_destroy(brutal_peer_cache);
        destroy_workqueue(brutal_free_wq);
        return ret;
    }
    tcp_prot_override = tcp_prot;
    tcp_prot_override.setsockopt = brutal_tcp_setsockopt;
    tcp_prot_override.getsockopt = brutal_tcp_getsockopt;

#ifdef _TRANSP_V6_H
    tcpv6_prot_override = tcpv6_prot;
    tcpv6_prot_override.setsockopt = brutal_tcpv6_setsockopt;
    tcpv6_prot_override.getsockopt = brutal_tcpv6_getsockopt;
#endif // _TRANSP_V6_H
    return 0;
}

void brutal_sockopt_exit(void)
{
    rcu_barrier();
    flush_workqueue(brutal_free_wq);
    rhashtable_destroy(&brutal_perip_groups);
    mempool_destroy(brutal_peer_pool);
    kmem_cache_destroy(brutal_peer_cache);
    destroy_workqueue(brutal_free_wq);
}

void brutal_sockopt_install(struct sock *sk)
{
    if (sk->sk_prot == &tcp_prot)
        sk->sk_prot = &tcp_prot_override;
#ifdef _TRANSP_V6_H
    else if (sk->sk_prot == &tcpv6_prot)
        sk->sk_prot = &tcpv6_prot_override;
#endif // _TRANSP_V6_H
    else
        WARN_ON_ONCE(sk->sk_family != AF_INET && sk->sk_family != AF_INET6);
}

static void brutal_restore_proto(struct proto **protp)
{
    struct proto *prot = READ_ONCE(*protp);

    if (prot == &tcp_prot_override)
        WRITE_ONCE(*protp, &tcp_prot);
#ifdef _TRANSP_V6_H
    else if (prot == &tcpv6_prot_override)
        WRITE_ONCE(*protp, &tcpv6_prot);
#endif // _TRANSP_V6_H
}

void brutal_sockopt_uninstall(struct sock *sk)
{
    brutal_restore_proto(&sk->sk_prot);
#if IS_ENABLED(CONFIG_TLS)
    if (inet_csk(sk)->icsk_ulp_ops &&
        !strcmp(inet_csk(sk)->icsk_ulp_ops->name, "tls"))
    {
        struct tls_context *ctx = tls_get_ctx(sk);

        // TLS retains the base proto for sockopts and restores it on close.
        if (ctx)
            brutal_restore_proto(&ctx->sk_proto);
    }
#endif
}
