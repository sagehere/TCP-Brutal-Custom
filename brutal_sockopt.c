// Groups and the application interface: TCP_BRUTAL_PARAMS / TCP_BRUTAL_VERSION
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

static struct kmem_cache *brutal_peer_cache;
static mempool_t *brutal_peer_pool;
static struct workqueue_struct *brutal_free_wq;

struct brutal_rule_stats
{
    struct percpu_counter sent_bytes;
    struct rhashtable peers;
    struct work_struct destroy_work;
    struct brutal_group *group;
    bool peers_initialized;
};

static const struct rhashtable_params brutal_perip_params = {
    .head_offset = offsetof(struct brutal_peer, node),
    .key_offset = offsetof(struct brutal_peer, key),
    .key_len = sizeof(struct brutal_peer_key),
    .automatic_shrinking = true,
};

static struct proto tcp_prot_override __ro_after_init;
#ifdef _TRANSP_V6_H
static struct proto tcpv6_prot_override __ro_after_init;
#endif

static void brutal_pacer_init(struct brutal_pacer *p, u8 type,
                              struct brutal_group *parent)
{
    refcount_set(&p->refcnt, 1);
    spin_lock_init(&p->lock);
    atomic_set(&p->members, 0);
    atomic64_set(&p->sent_bytes, 0);
    p->parent = parent;
    p->type = type;
}

static void brutal_group_init(struct brutal_group *g, u64 id)
{
    brutal_pacer_init(&g->pacer, BRUTAL_PACER_GROUP, NULL);
    spin_lock_init(&g->cfg.lock);
    seqcount_init(&g->cfg.seq);
    atomic_set(&g->cfg.generation, 0);
    atomic_set(&g->ip_groups, 0);
    g->id = id;
    g->cfg.rate = INIT_PACING_RATE;
    g->cfg.cwnd_gain = INIT_CWND_GAIN;
}

struct brutal_group *brutal_group_alloc(u64 id, gfp_t gfp)
{
    struct brutal_group *g = kzalloc(sizeof(*g), gfp);

    if (!g)
        return NULL;
    brutal_group_init(g, id);
    return g;
}

static struct brutal_peer *brutal_peer_alloc(void)
{
    struct brutal_peer *peer = mempool_alloc(brutal_peer_pool, GFP_ATOMIC);

    if (!peer)
        return NULL;
    memset(peer, 0, sizeof(*peer));
    brutal_pacer_init(&peer->pacer, BRUTAL_PACER_PEER, NULL);
    spin_lock_init(&peer->lifecycle_lock);
    return peer;
}

static struct brutal_group *brutal_pacer_config_group(struct brutal_pacer *p)
{
    return p->parent ? p->parent : container_of(p, struct brutal_group, pacer);
}

static struct brutal_rule_stats *brutal_group_rule_stats(struct brutal_group *g)
{
    return READ_ONCE(g->rule_stats);
}

void brutal_pacer_get(struct brutal_pacer *p)
{
    refcount_inc(&p->refcnt);
}

bool brutal_peer_try_get(struct brutal_peer *peer)
{
    bool ok;

    spin_lock_bh(&peer->lifecycle_lock);
    ok = refcount_inc_not_zero(&peer->pacer.refcnt);
    spin_unlock_bh(&peer->lifecycle_lock);
    return ok;
}

u64 brutal_pacer_id(struct brutal_pacer *p)
{
    return brutal_pacer_config_group(p)->id;
}

u64 brutal_group_rate(struct brutal_pacer *p)
{
    u64 rate;

    brutal_group_get_config(p, &rate, NULL, NULL, NULL);
    return rate;
}

u32 brutal_group_cwnd_gain(struct brutal_pacer *p)
{
    u32 gain;

    brutal_group_get_config(p, NULL, &gain, NULL, NULL);
    return gain;
}

int brutal_group_enable_rule_stats(struct brutal_group *g, bool perip)
{
    struct brutal_rule_stats *stats = kzalloc(sizeof(*stats), GFP_KERNEL);
    struct brutal_pacer **fallbacks = NULL;
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
        ret = rhashtable_init(&stats->peers, &brutal_perip_params);
        if (ret)
            goto fail;
        stats->peers_initialized = true;

        fallbacks = kcalloc(BRUTAL_FALLBACK_PACERS, sizeof(*fallbacks),
                            GFP_KERNEL);
        if (!fallbacks)
        {
            ret = -ENOMEM;
            goto fail;
        }
        for (i = 0; i < BRUTAL_FALLBACK_PACERS; i++)
        {
            fallbacks[i] = kzalloc(sizeof(*fallbacks[i]), GFP_KERNEL);
            if (!fallbacks[i])
            {
                ret = -ENOMEM;
                goto fail;
            }
            brutal_pacer_init(fallbacks[i], BRUTAL_PACER_FALLBACK, g);
            refcount_inc(&g->pacer.refcnt);
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
        refcount_dec(&g->pacer.refcnt);
    }
    kfree(fallbacks);
    if (stats->peers_initialized)
        rhashtable_destroy(&stats->peers);
    percpu_counter_destroy(&stats->sent_bytes);
    kfree(stats);
    return ret ?: -ENOMEM;
}

void brutal_group_account_sent(struct brutal_group *g, u64 bytes)
{
    struct brutal_rule_stats *stats = READ_ONCE(g->rule_stats);

    if (stats)
        percpu_counter_add(&stats->sent_bytes, bytes);
    else
        atomic64_add(bytes, &g->pacer.sent_bytes);
}

u64 brutal_group_sent(struct brutal_group *g)
{
    struct brutal_rule_stats *stats = READ_ONCE(g->rule_stats);

    return stats ? percpu_counter_sum_positive(&stats->sent_bytes)
                 : atomic64_read(&g->pacer.sent_bytes);
}

u16 brutal_group_generation(struct brutal_pacer *p)
{
    return (u16)atomic_read(&brutal_pacer_config_group(p)->cfg.generation);
}

void brutal_group_get_config(struct brutal_pacer *p, u64 *rate, u32 *gain,
                             bool *locked, u16 *generation)
{
    struct brutal_rate_cfg *cfg = &brutal_pacer_config_group(p)->cfg;
    unsigned int seq;
    u16 gen;

    do
    {
        seq = read_seqcount_begin(&cfg->seq);
        if (rate)
            *rate = READ_ONCE(cfg->rate);
        if (gain)
            *gain = READ_ONCE(cfg->cwnd_gain);
        if (locked)
            *locked = READ_ONCE(cfg->locked);
        gen = (u16)atomic_read(&cfg->generation);
    } while (read_seqcount_retry(&cfg->seq, seq));

    if (generation)
        *generation = gen;
}

void brutal_group_set_config(struct brutal_pacer *p, u64 rate, u32 gain,
                             bool locked)
{
    struct brutal_rate_cfg *cfg = &brutal_pacer_config_group(p)->cfg;

    spin_lock_bh(&cfg->lock);
    write_seqcount_begin(&cfg->seq);
    WRITE_ONCE(cfg->rate, rate);
    WRITE_ONCE(cfg->cwnd_gain, gain);
    WRITE_ONCE(cfg->locked, locked);
    atomic_inc(&cfg->generation);
    write_seqcount_end(&cfg->seq);
    spin_unlock_bh(&cfg->lock);
}

bool brutal_group_locked(struct brutal_pacer *p)
{
    bool locked;

    brutal_group_get_config(p, NULL, NULL, &locked, NULL);
    return locked;
}

int brutal_group_dump_peers(struct seq_file *m, struct brutal_group *parent)
{
    struct brutal_rule_stats *stats = brutal_group_rule_stats(parent);
    struct rhashtable_iter iter;
    struct brutal_peer *peer;

    if (!stats || !stats->peers_initialized)
        return 0;

    rhashtable_walk_enter(&stats->peers, &iter);
    rhashtable_walk_start(&iter);
    for (;;)
    {
        u64 rate;
        u32 gain;

        peer = rhashtable_walk_next(&iter);
        if (IS_ERR(peer))
        {
            if (PTR_ERR(peer) == -EAGAIN)
                continue;
            break;
        }
        if (!peer)
            break;
        if (!atomic_read(&peer->pacer.members))
            continue;

        brutal_group_get_config(&peer->pacer, &rate, &gain, NULL, NULL);
        if (peer->key.family == AF_INET)
            seq_printf(m, "ip=%pI4 family=4", &peer->key.v4);
        else
            seq_printf(m, "ip=%pI6c family=6", &peer->key.v6);
        seq_printf(m, " rule=%llu rate=%llu gain=%u members=%u sent=%llu\n",
                   parent->id, rate, gain,
                   atomic_read(&peer->pacer.members),
                   atomic64_read(&peer->pacer.sent_bytes));
    }
    rhashtable_walk_stop(&iter);
    rhashtable_walk_exit(&iter);
    return 0;
}

static void brutal_perip_key(const struct sock *sk, struct brutal_peer_key *key)
{
    memset(key, 0, sizeof(*key));
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

static struct brutal_pacer *brutal_fallback_group_get(
    const struct brutal_peer_key *key, struct brutal_group *parent,
    struct net *net)
{
    struct brutal_pacer **fallbacks = READ_ONCE(parent->fallbacks);
    struct brutal_pacer *p;
    u32 hash;

    if (!fallbacks)
        return NULL;
    if (key->family == AF_INET)
        hash = jhash_1word((__force u32)key->v4, (u32)parent->id);
    else
        hash = jhash(key->v6.s6_addr, sizeof(key->v6.s6_addr),
                     (u32)parent->id);
    p = fallbacks[hash & (BRUTAL_FALLBACK_PACERS - 1)];
    brutal_pacer_get(p);
    brutal_group_put(parent);
    brutal_net_peer_fallback(net);
    return p;
}

struct brutal_pacer *brutal_perip_group_get(struct sock *sk, struct brutal_group *parent)
{
    struct brutal_rule_stats *stats = brutal_group_rule_stats(parent);
    struct brutal_peer *peer, *new_peer;
    struct brutal_peer_key key;
    struct net *net = sock_net(sk);

    if (WARN_ON_ONCE(!stats || !stats->peers_initialized))
        return NULL;

    brutal_perip_key(sk, &key);
    rcu_read_lock();
    peer = rhashtable_lookup_fast(&stats->peers, &key, brutal_perip_params);
    if (peer && !brutal_peer_try_get(peer))
        peer = NULL;
    rcu_read_unlock();
    if (peer)
    {
        brutal_group_put(parent);
        return &peer->pacer;
    }

    new_peer = brutal_peer_alloc();
    if (!new_peer)
    {
        brutal_net_peer_alloc_failed(net);
        return brutal_fallback_group_get(&key, parent, net);
    }
    new_peer->pacer.parent = parent;
    new_peer->net = net;
    new_peer->key = key;

    for (;;)
    {
        peer = rhashtable_lookup_get_insert_fast(&stats->peers, &new_peer->node,
                                                 brutal_perip_params);
        if (IS_ERR(peer))
        {
            brutal_net_peer_insert_failed(net);
            mempool_free(new_peer, brutal_peer_pool);
            return brutal_fallback_group_get(&key, parent, net);
        }
        if (!peer)
            break;
        if (brutal_peer_try_get(peer))
        {
            brutal_group_put(parent);
            mempool_free(new_peer, brutal_peer_pool);
            return &peer->pacer;
        }
        cpu_relax();
    }

    atomic_inc(&parent->ip_groups);
    brutal_net_peer_added(net);
    return &new_peer->pacer;
}

static void brutal_peer_free_rcu(struct rcu_head *rcu)
{
    struct brutal_peer *peer = container_of(rcu, struct brutal_peer, rcu);

    brutal_group_put(peer->pacer.parent);
    mempool_free(peer, brutal_peer_pool);
}

static void brutal_rule_group_free_work(struct work_struct *work)
{
    struct brutal_rule_stats *stats =
        container_of(work, struct brutal_rule_stats, destroy_work);

    if (stats->peers_initialized)
        rhashtable_destroy(&stats->peers);
    percpu_counter_destroy(&stats->sent_bytes);
    kfree(stats->group);
    kfree(stats);
}

void brutal_pacer_put(struct brutal_pacer *p)
{
    if (p->type == BRUTAL_PACER_PEER)
    {
        struct brutal_peer *peer = container_of(p, struct brutal_peer, pacer);
        struct brutal_group *parent = p->parent;
        struct brutal_rule_stats *stats;

        spin_lock_bh(&peer->lifecycle_lock);
        if (!refcount_dec_and_test(&p->refcnt))
        {
            spin_unlock_bh(&peer->lifecycle_lock);
            return;
        }
        stats = brutal_group_rule_stats(parent);
        if (WARN_ON_ONCE(!stats || !stats->peers_initialized))
        {
            spin_unlock_bh(&peer->lifecycle_lock);
            brutal_group_put(parent);
            mempool_free(peer, brutal_peer_pool);
            return;
        }
        rhashtable_remove_fast(&stats->peers, &peer->node,
                               brutal_perip_params);
        spin_unlock_bh(&peer->lifecycle_lock);

        atomic_dec(&parent->ip_groups);
        brutal_net_peer_removed(peer->net);
        call_rcu(&peer->rcu, brutal_peer_free_rcu);
        return;
    }

    if (!refcount_dec_and_test(&p->refcnt))
        return;

    switch (p->type)
    {
    case BRUTAL_PACER_FALLBACK:
    {
        struct brutal_group *parent = p->parent;

        brutal_group_put(parent);
        kfree(p);
        return;
    }
    case BRUTAL_PACER_GROUP:
    default:
    {
        struct brutal_group *g = container_of(p, struct brutal_group, pacer);

        if (g->rule_stats)
        {
            struct brutal_rule_stats *stats = g->rule_stats;

            INIT_WORK(&stats->destroy_work, brutal_rule_group_free_work);
            queue_work(brutal_free_wq, &stats->destroy_work);
            return;
        }
        if (g->net)
        {
            brutal_app_group_remove(g);
            return;
        }
        kfree(g);
        return;
    }
    }
}

void brutal_group_put(struct brutal_group *g)
{
    brutal_pacer_put(&g->pacer);
}

void brutal_group_release_fallbacks(struct brutal_group *g)
{
    struct brutal_pacer **fallbacks = xchg(&g->fallbacks, NULL);
    int i;

    if (!fallbacks)
        return;
    for (i = 0; i < BRUTAL_FALLBACK_PACERS; i++)
        brutal_pacer_put(fallbacks[i]);
    kfree(fallbacks);
}

void brutal_group_join(struct brutal *brutal, struct brutal_pacer *p)
{
    brutal->group = p;
    atomic_inc(&p->members);
    if (p->parent)
        atomic_inc(&p->parent->pacer.members);
}

void brutal_group_leave(struct sock *sk)
{
    struct brutal *brutal = inet_csk_ca(sk);
    struct brutal_pacer *p = brutal->group;

    if (!p)
        return;
    brutal_settle_reservation(sk);
    brutal->group = NULL;
    atomic_dec(&p->members);
    if (p->parent)
        atomic_dec(&p->parent->pacer.members);
    brutal_pacer_put(p);
}

static int brutal_set_params(struct sock *sk, sockptr_t optval,
                             unsigned int optlen)
{
    struct brutal *brutal = inet_csk_ca(sk);
    struct brutal_params params = {};

    if (optlen < BRUTAL_PARAMS_V1_SIZE)
        return -EINVAL;
    if (copy_from_sockptr(&params, optval,
                          min_t(unsigned int, optlen, sizeof(params))))
        return -EFAULT;
    if (optlen < sizeof(params))
        params.group_id = 0;

    if (params.rate < MIN_PACING_RATE || params.rate > MAX_PACING_RATE)
        return -EINVAL;
    if (params.cwnd_gain < MIN_CWND_GAIN || params.cwnd_gain > MAX_CWND_GAIN)
        return -EINVAL;

    lock_sock(sk);
    if (inet_csk(sk)->icsk_ca_ops != &tcp_brutal_ops)
    {
        release_sock(sk);
        return -ENOPROTOOPT;
    }
    if (brutal->group && brutal_group_locked(brutal->group))
    {
        release_sock(sk);
        return -EPERM;
    }
    if (!params.group_id)
        brutal_group_leave(sk);
    else if (!brutal->group || brutal_pacer_id(brutal->group) != params.group_id)
    {
        struct brutal_group *g = brutal_app_group_get(sk, params.group_id);

        if (!g)
        {
            release_sock(sk);
            return -ENOMEM;
        }
        brutal_group_leave(sk);
        brutal_group_join(brutal, &g->pacer);
    }
    if (brutal->group)
        brutal_group_set_config(brutal->group, params.rate, params.cwnd_gain,
                                brutal_group_locked(brutal->group));
    brutal->rate = params.rate;
    brutal->cwnd_gain = params.cwnd_gain;
    brutal_update_rate(sk);
    release_sock(sk);
    return 0;
}

static int brutal_get_params(struct sock *sk, char __user *optval,
                             int __user *optlen)
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
        params.group_id = brutal_pacer_id(brutal->group);
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

static int brutal_tcp_setsockopt(struct sock *sk, int level, int optname,
                                 sockptr_t optval, unsigned int optlen)
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_set_params(sk, optval, optlen);
    return tcp_prot.setsockopt(sk, level, optname, optval, optlen);
}

static int brutal_tcp_getsockopt(struct sock *sk, int level, int optname,
                                 char __user *optval, int __user *optlen)
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_get_params(sk, optval, optlen);
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_VERSION)
        return brutal_get_version(optval, optlen);
    return tcp_prot.getsockopt(sk, level, optname, optval, optlen);
}

#ifdef _TRANSP_V6_H
static int brutal_tcpv6_setsockopt(struct sock *sk, int level, int optname,
                                   sockptr_t optval, unsigned int optlen)
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_set_params(sk, optval, optlen);
    return tcpv6_prot.setsockopt(sk, level, optname, optval, optlen);
}

static int brutal_tcpv6_getsockopt(struct sock *sk, int level, int optname,
                                   char __user *optval, int __user *optlen)
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_get_params(sk, optval, optlen);
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_VERSION)
        return brutal_get_version(optval, optlen);
    return tcpv6_prot.getsockopt(sk, level, optname, optval, optlen);
}
#endif

int __init brutal_sockopt_init(void)
{
    brutal_free_wq = alloc_workqueue("tcp_brutal_free",
                                     WQ_UNBOUND | WQ_MEM_RECLAIM, 0);
    if (!brutal_free_wq)
        return -ENOMEM;
    brutal_peer_cache = kmem_cache_create("tcp_brutal_peer",
                                          sizeof(struct brutal_peer), 0,
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

    tcp_prot_override = tcp_prot;
    tcp_prot_override.setsockopt = brutal_tcp_setsockopt;
    tcp_prot_override.getsockopt = brutal_tcp_getsockopt;
#ifdef _TRANSP_V6_H
    tcpv6_prot_override = tcpv6_prot;
    tcpv6_prot_override.setsockopt = brutal_tcpv6_setsockopt;
    tcpv6_prot_override.getsockopt = brutal_tcpv6_getsockopt;
#endif
    return 0;
}

void brutal_sockopt_exit(void)
{
    rcu_barrier();
    flush_workqueue(brutal_free_wq);
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
#endif
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
#endif
}

void brutal_sockopt_uninstall(struct sock *sk)
{
    brutal_restore_proto(&sk->sk_prot);
#if IS_ENABLED(CONFIG_TLS)
    if (inet_csk(sk)->icsk_ulp_ops &&
        !strcmp(inet_csk(sk)->icsk_ulp_ops->name, "tls"))
    {
        struct tls_context *ctx = tls_get_ctx(sk);

        if (ctx)
            brutal_restore_proto(&ctx->sk_proto);
    }
#endif
}
