// Destination rules: /proc/net/tcp_brutal/rules
//
// Every connection to a rule's prefix joins the rule's group, without
// application support. The route must select brutal for the prefix
// ("ip route ... congctl lock brutal"); brutalctl in tools/ does both.
#include <linux/capability.h>
#include <linux/bitmap.h>
#include <linux/inet.h>
#include <linux/mutex.h>
#include <linux/proc_fs.h>
#include <linux/rculist.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/xarray.h>
#include <net/ipv6.h>
#include <net/net_namespace.h>
#include <net/netns/generic.h>
#include "brutal.h"

#define RULES_MAX_CMD_LEN 256

struct brutal_prefix_key
{
    u8 family;
    u8 plen;
    u8 padding[2];
    union
    {
        __be32 v4;
        struct in6_addr v6;
    };
};

struct brutal_rule
{
    struct list_head list;
    struct list_head free_list;
    struct rhash_head exact_node;
    struct rhash_head prefix_node;
    struct brutal_peer_key exact_key;
    struct brutal_prefix_key prefix_key;
    u8 family;
    u8 plen;
    union
    {
        __be32 v4;
        struct in6_addr v6;
    };
    struct brutal_group *group;
    bool perip;
};

struct brutal_net
{
    struct list_head rules;
    struct mutex rules_mutex;
    struct rhashtable exact_hosts;
    struct rhashtable prefixes;
    struct rhashtable app_groups;
    DECLARE_BITMAP(v4_prefixes, 33);
    DECLARE_BITMAP(v6_prefixes, 129);
    u32 v4_prefix_counts[33];
    u32 v6_prefix_counts[129];
    struct xarray rules_by_id;
    unsigned long rule_next_id;
    atomic64_t peer_alloc_failures;
    atomic64_t peer_insert_failures;
    atomic64_t peer_fallback_connections;
    atomic64_t peer_budget_fallbacks;
    atomic_t peer_slots;
    atomic_t peak_peer_slots;
    atomic_t active_peers;
    atomic_t peak_peers;
    u32 max_peers;
    struct brutal_rule __rcu *default_v4;
    struct brutal_rule __rcu *default_v6;
};

struct brutal_peers_seq
{
    struct net *net;
    struct brutal_group *group;
    struct rhashtable_iter iter;
    struct brutal_peer *peer;
    u64 rule_id;
    loff_t index;
    bool iter_entered;
    bool iter_started;
};

static const struct rhashtable_params brutal_exact_params = {
    .head_offset = offsetof(struct brutal_rule, exact_node),
    .key_offset = offsetof(struct brutal_rule, exact_key),
    .key_len = sizeof(struct brutal_peer_key),
    .automatic_shrinking = true,
};

static const struct rhashtable_params brutal_prefix_params = {
    .head_offset = offsetof(struct brutal_rule, prefix_node),
    .key_offset = offsetof(struct brutal_rule, prefix_key),
    .key_len = sizeof(struct brutal_prefix_key),
    .automatic_shrinking = true,
};

static const struct rhashtable_params brutal_app_params = {
    .head_offset = offsetof(struct brutal_group, app_node),
    .key_offset = offsetof(struct brutal_group, app_key),
    .key_len = sizeof(struct brutal_app_key),
    .automatic_shrinking = true,
};

static unsigned int brutal_net_id;

static struct brutal_net *brutal_pernet(struct net *net)
{
    return net_generic(net, brutal_net_id);
}

static void brutal_app_group_free_rcu(struct rcu_head *rcu)
{
    struct brutal_group *g = container_of(rcu, struct brutal_group, rcu);

    kfree(g);
}

struct brutal_group *brutal_app_group_get(struct sock *sk, u64 id)
{
    struct brutal_net *bn = brutal_pernet(sock_net(sk));
    struct brutal_app_key key = {};
    struct brutal_group *g, *ng;

    key.uid = sk->sk_uid;
    key.id = id;
    ng = brutal_group_alloc(id, GFP_KERNEL);
    if (!ng)
        return NULL;
    ng->net = sock_net(sk);
    ng->app_key = key;

    for (;;)
    {
        rcu_read_lock();
        g = rhashtable_lookup_fast(&bn->app_groups, &key, brutal_app_params);
        if (g && !refcount_inc_not_zero(&g->pacer.refcnt))
            g = NULL;
        rcu_read_unlock();
        if (g)
        {
            kfree(ng);
            return g;
        }

        g = rhashtable_lookup_get_insert_fast(&bn->app_groups, &ng->app_node,
                                              brutal_app_params);
        if (IS_ERR(g))
        {
            kfree(ng);
            return NULL;
        }
        if (!g)
            return ng;
        if (refcount_inc_not_zero(&g->pacer.refcnt))
        {
            kfree(ng);
            return g;
        }
        cond_resched();
    }
}

void brutal_app_group_remove(struct brutal_group *g)
{
    struct brutal_net *bn = brutal_pernet(g->net);

    rhashtable_remove_fast(&bn->app_groups, &g->app_node, brutal_app_params);
    call_rcu(&g->rcu, brutal_app_group_free_rcu);
}

void brutal_net_peer_alloc_failed(struct net *net)
{
    atomic64_inc(&brutal_pernet(net)->peer_alloc_failures);
}

void brutal_net_peer_insert_failed(struct net *net)
{
    atomic64_inc(&brutal_pernet(net)->peer_insert_failures);
}

void brutal_net_peer_fallback(struct net *net)
{
    atomic64_inc(&brutal_pernet(net)->peer_fallback_connections);
}

static bool brutal_slot_try_reserve(atomic_t *slots, u32 limit)
{
    int old;

    for (;;)
    {
        old = atomic_read(slots);
        if (old == INT_MAX || (limit && old >= limit))
            return false;
        if (atomic_cmpxchg(slots, old, old + 1) == old)
            return true;
        cpu_relax();
    }
}

static void brutal_peak_update(atomic_t *peak, int value)
{
    int old = atomic_read(peak);

    while (value > old && atomic_cmpxchg(peak, old, value) != old)
        old = atomic_read(peak);
}

bool brutal_peer_budget_try_reserve(struct net *net, struct brutal_group *parent)
{
    struct brutal_net *bn = brutal_pernet(net);
    struct brutal_rule_stats *stats = READ_ONCE(parent->rule_stats);
    int slots;

    if (WARN_ON_ONCE(!stats))
        return false;
    if (!brutal_slot_try_reserve(&bn->peer_slots, READ_ONCE(bn->max_peers)))
        return false;
    if (!brutal_slot_try_reserve(&stats->peer_slots, READ_ONCE(stats->max_peers)))
    {
        atomic_dec(&bn->peer_slots);
        return false;
    }
    slots = atomic_read(&bn->peer_slots);
    brutal_peak_update(&bn->peak_peer_slots, slots);
    slots = atomic_read(&stats->peer_slots);
    brutal_peak_update(&stats->peak_peer_slots, slots);
    return true;
}

void brutal_peer_budget_release(struct net *net, struct brutal_group *parent)
{
    struct brutal_rule_stats *stats = READ_ONCE(parent->rule_stats);

    if (WARN_ON_ONCE(!stats))
        return;
    atomic_dec(&stats->peer_slots);
    atomic_dec(&brutal_pernet(net)->peer_slots);
}

void brutal_net_peer_budget_fallback(struct net *net, struct brutal_group *parent)
{
    struct brutal_rule_stats *stats = READ_ONCE(parent->rule_stats);

    atomic64_inc(&brutal_pernet(net)->peer_budget_fallbacks);
    if (stats)
        atomic64_inc(&stats->peer_budget_fallbacks);
}

void brutal_net_peer_added(struct net *net)
{
    struct brutal_net *bn = brutal_pernet(net);
    int active = atomic_inc_return(&bn->active_peers);
    int peak = atomic_read(&bn->peak_peers);

    while (active > peak &&
           atomic_cmpxchg(&bn->peak_peers, peak, active) != peak)
        peak = atomic_read(&bn->peak_peers);
}

void brutal_net_peer_removed(struct net *net)
{
    atomic_dec(&brutal_pernet(net)->active_peers);
}

static void brutal_sock_prefix_key(const struct sock *sk, u8 plen,
                                   struct brutal_prefix_key *key)
{
    memset(key, 0, sizeof(*key));
#if IS_ENABLED(CONFIG_IPV6)
    if (sk->sk_family == AF_INET6 && !ipv6_addr_v4mapped(&sk->sk_v6_daddr))
    {
        key->family = AF_INET6;
        key->plen = plen;
        ipv6_addr_prefix(&key->v6, &sk->sk_v6_daddr, plen);
        return;
    }
#endif
    key->family = AF_INET;
    key->plen = plen;
    key->v4 = sk->sk_daddr & htonl(~0u << (32 - plen));
}

static void brutal_sock_exact_key(const struct sock *sk,
                                  struct brutal_peer_key *key)
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

static void brutal_rule_exact_key(const struct brutal_rule *r,
                                  struct brutal_peer_key *key)
{
    memset(key, 0, sizeof(*key));
    key->family = r->family;
    if (r->family == AF_INET)
        key->v4 = r->v4;
    else
        key->v6 = r->v6;
}

static void brutal_rule_prefix_key(const struct brutal_rule *r,
                                   struct brutal_prefix_key *key)
{
    memset(key, 0, sizeof(*key));
    key->family = r->family;
    key->plen = r->plen;
    if (r->family == AF_INET)
        key->v4 = r->v4;
    else
        key->v6 = r->v6;
}

static struct brutal_rule *brutal_exact_lookup(struct brutal_net *bn,
                                               const struct sock *sk)
{
    struct brutal_peer_key key;

    brutal_sock_exact_key(sk, &key);
    return rhashtable_lookup_fast(&bn->exact_hosts, &key,
                                  brutal_exact_params);
}

static struct brutal_rule *brutal_prefix_lookup(struct brutal_net *bn,
                                                const struct sock *sk)
{
    struct brutal_prefix_key key;
    unsigned long *active;
    int plen;

#if IS_ENABLED(CONFIG_IPV6)
    if (sk->sk_family == AF_INET6 && !ipv6_addr_v4mapped(&sk->sk_v6_daddr))
    {
        active = bn->v6_prefixes;
        plen = 127;
    }
    else
#endif
    {
        active = bn->v4_prefixes;
        plen = 31;
    }
    for (; plen > 0; plen--)
    {
        struct brutal_rule *r;

        if (!test_bit(plen, active))
            continue;
        brutal_sock_prefix_key(sk, plen, &key);
        r = rhashtable_lookup_fast(&bn->prefixes, &key,
                                   brutal_prefix_params);
        if (r)
            return r;
    }
    return NULL;
}

void brutal_apply_rule(struct sock *sk, struct brutal *brutal)
{
    struct brutal_net *bn = brutal_pernet(sock_net(sk));
    struct brutal_rule *best;

    rcu_read_lock();
    best = brutal_exact_lookup(bn, sk);
    if (best)
        goto found;
    best = brutal_prefix_lookup(bn, sk);
    if (best)
        goto found;
#if IS_ENABLED(CONFIG_IPV6)
    best = sk->sk_family == AF_INET6 &&
                   !ipv6_addr_v4mapped(&sk->sk_v6_daddr)
               ? rcu_dereference(bn->default_v6)
               : rcu_dereference(bn->default_v4);
#else
    best = rcu_dereference(bn->default_v4);
#endif
found:
    if (best)
    {
        brutal_pacer_get(&best->group->pacer);
        if (best->perip)
        {
            struct brutal_pacer *p = brutal_perip_group_get(sk, best->group);

            if (p)
                brutal_group_join(brutal, p);
            else
            {
                brutal_net_peer_fallback(sock_net(sk));
                pr_warn_ratelimited("tcp_brutal: per-IP group allocation failed; using shared rule group\n");
                brutal_group_join(brutal, &best->group->pacer);
            }
        }
        else
            brutal_group_join(brutal, &best->group->pacer);
    }
    rcu_read_unlock();
}

static int brutal_parse_prefix(char *s, struct brutal_rule *r)
{
    char *slash = strchr(s, '/');
    int plen = -1;

    if (slash)
    {
        *slash++ = 0;
        if (kstrtoint(slash, 10, &plen) || plen < 0)
            return -EINVAL;
    }
    if (in4_pton(s, -1, (u8 *)&r->v4, -1, NULL))
    {
        r->family = AF_INET;
        r->plen = plen < 0 ? 32 : plen;
        if (plen > 32)
            return -EINVAL;
        r->v4 &= r->plen ? htonl(~0u << (32 - r->plen)) : 0;
        return 0;
    }
    if (in6_pton(s, -1, r->v6.s6_addr, -1, NULL))
    {
        struct in6_addr addr;

        r->family = AF_INET6;
        r->plen = plen < 0 ? 128 : plen;
        if (plen > 128)
            return -EINVAL;
        addr = r->v6;
        ipv6_addr_prefix(&r->v6, &addr, r->plen);
        return 0;
    }
    return -EINVAL;
}

static bool brutal_rule_is_exact(const struct brutal_rule *r)
{
    return r->plen == (r->family == AF_INET ? 32 : 128);
}

static struct brutal_rule *brutal_rule_find(struct brutal_net *bn,
                                            const struct brutal_rule *key)
{
    struct brutal_prefix_key prefix_key;
    struct brutal_rule *r = NULL;

    if (!key->plen)
    {
        return rcu_dereference_protected(
            key->family == AF_INET ? bn->default_v4 : bn->default_v6,
            lockdep_is_held(&bn->rules_mutex));
    }
    if (brutal_rule_is_exact(key))
    {
        struct brutal_peer_key exact_key;

        brutal_rule_exact_key(key, &exact_key);
        rcu_read_lock();
        r = rhashtable_lookup_fast(&bn->exact_hosts, &exact_key,
                                   brutal_exact_params);
        rcu_read_unlock();
        return r;
    }

    brutal_rule_prefix_key(key, &prefix_key);
    rcu_read_lock();
    r = rhashtable_lookup_fast(&bn->prefixes, &prefix_key,
                               brutal_prefix_params);
    rcu_read_unlock();
    return r;
}

static int brutal_rule_index_add(struct brutal_net *bn, struct brutal_rule *r)
{
    int ret;

    if (!r->plen)
    {
        if (r->family == AF_INET)
            rcu_assign_pointer(bn->default_v4, r);
        else
            rcu_assign_pointer(bn->default_v6, r);
        return 0;
    }
    if (brutal_rule_is_exact(r))
    {
        brutal_rule_exact_key(r, &r->exact_key);
        return rhashtable_insert_fast(&bn->exact_hosts, &r->exact_node,
                                      brutal_exact_params);
    }

    brutal_rule_prefix_key(r, &r->prefix_key);
    ret = rhashtable_insert_fast(&bn->prefixes, &r->prefix_node,
                                 brutal_prefix_params);
    if (ret)
        return ret;
    if (r->family == AF_INET)
    {
        if (++bn->v4_prefix_counts[r->plen] == 1)
            set_bit(r->plen, bn->v4_prefixes);
    }
    else if (++bn->v6_prefix_counts[r->plen] == 1)
        set_bit(r->plen, bn->v6_prefixes);
    return 0;
}

static void brutal_rule_index_del(struct brutal_net *bn, struct brutal_rule *r)
{
    if (!r->plen)
    {
        if (r->family == AF_INET)
            RCU_INIT_POINTER(bn->default_v4, NULL);
        else
            RCU_INIT_POINTER(bn->default_v6, NULL);
    }
    else if (brutal_rule_is_exact(r))
        rhashtable_remove_fast(&bn->exact_hosts, &r->exact_node,
                               brutal_exact_params);
    else
    {
        rhashtable_remove_fast(&bn->prefixes, &r->prefix_node,
                               brutal_prefix_params);
        if (r->family == AF_INET)
        {
            if (!--bn->v4_prefix_counts[r->plen])
                clear_bit(r->plen, bn->v4_prefixes);
        }
        else if (!--bn->v6_prefix_counts[r->plen])
            clear_bit(r->plen, bn->v6_prefixes);
    }
}

static int brutal_rule_publish(struct brutal_net *bn, struct brutal_rule *r)
{
    int ret;

    ret = xa_insert(&bn->rules_by_id, r->group->id, r, GFP_KERNEL);
    if (ret)
        return ret;
    ret = brutal_rule_index_add(bn, r);
    if (ret)
    {
        xa_erase(&bn->rules_by_id, r->group->id);
        return ret;
    }
    list_add_tail_rcu(&r->list, &bn->rules);
    return 0;
}

static void brutal_rule_unpublish(struct brutal_net *bn, struct brutal_rule *r)
{
    brutal_rule_index_del(bn, r);
    xa_erase(&bn->rules_by_id, r->group->id);
    list_del_rcu(&r->list);
}

static void brutal_rule_free(struct brutal_rule *r)
{
    synchronize_rcu();
    brutal_group_release_fallbacks(r->group);
    brutal_group_put(r->group);
    kfree(r);
}

static int brutal_rule_add(struct brutal_net *bn, char *args)
{
    struct brutal_rule key = {}, *r;
    struct brutal_group *g;
    u64 rate = 0;
    u64 aggregate_rate = 0;
    u32 gain = INIT_CWND_GAIN;
    bool lock = true;
    bool perip = false, created = false;
    bool maxpeers_set = false;
    bool aggregate_set = false;
    u32 maxpeers = 0;
    char *tok = strsep(&args, " ");
    int ret = 0;

    if (!tok || (ret = brutal_parse_prefix(tok, &key)))
        return tok ? ret : -EINVAL;
    while ((tok = strsep(&args, " ")))
    {
        if (!*tok)
            continue;
        if (!strncmp(tok, "rate=", 5))
            ret = kstrtou64(tok + 5, 10, &rate);
        else if (!strncmp(tok, "aggregate=", 10))
        {
            ret = kstrtou64(tok + 10, 10, &aggregate_rate);
            aggregate_set = true;
        }
        else if (!strncmp(tok, "gain=", 5))
            ret = kstrtou32(tok + 5, 10, &gain);
        else if (!strcmp(tok, "nolock"))
            lock = false;
        else if (!strcmp(tok, "lock"))
            lock = true;
        else if (!strcmp(tok, "perip"))
            perip = true;
        else if (!strncmp(tok, "maxpeers=", 9))
        {
            ret = kstrtou32(tok + 9, 10, &maxpeers);
            if (!ret && maxpeers > INT_MAX)
                ret = -ERANGE;
            maxpeers_set = true;
        }
        else
            ret = -EINVAL;
        if (ret)
            return -EINVAL;
    }
    if (rate < MIN_PACING_RATE || rate > MAX_PACING_RATE ||
        gain < MIN_CWND_GAIN || gain > MAX_CWND_GAIN)
        return -EINVAL;
    if (perip && !lock)
        return -EINVAL;
    if (maxpeers_set && !perip)
        return -EINVAL;
    if (aggregate_set && !perip)
        return -EINVAL;
    if (aggregate_rate &&
        (aggregate_rate < MIN_PACING_RATE || aggregate_rate > MAX_PACING_RATE))
        return -EINVAL;

    mutex_lock(&bn->rules_mutex);
    r = brutal_rule_find(bn, &key);
    if (!r)
    {
        unsigned long id;

        if (bn->rule_next_id == ULONG_MAX)
        {
            mutex_unlock(&bn->rules_mutex);
            return -ENOSPC;
        }
        id = ++bn->rule_next_id;
        r = kmemdup(&key, sizeof(key), GFP_KERNEL);
        g = r ? brutal_group_alloc(id, GFP_KERNEL) : NULL;
        if (!g)
        {
            mutex_unlock(&bn->rules_mutex);
            kfree(r);
            return -ENOMEM;
        }
        ret = brutal_group_enable_rule_stats(g, perip);
        if (ret)
        {
            brutal_group_put(g);
            mutex_unlock(&bn->rules_mutex);
            kfree(r);
            return ret;
        }
        r->group = g;
        r->perip = perip;
        WRITE_ONCE(g->rule_stats->max_peers, maxpeers);
        INIT_LIST_HEAD(&r->free_list);
        brutal_group_set_rule_config(&g->pacer, rate, gain, lock,
                                     aggregate_rate);
        ret = brutal_rule_publish(bn, r);
        if (ret)
        {
            brutal_group_release_fallbacks(g);
            brutal_group_put(g);
            mutex_unlock(&bn->rules_mutex);
            kfree(r);
            return ret;
        }
        created = true;
    }
    else if (r->perip != perip)
    {
        mutex_unlock(&bn->rules_mutex);
        return -EINVAL;
    }
    g = r->group;
    if (!created)
    {
        if (maxpeers_set)
            WRITE_ONCE(g->rule_stats->max_peers, maxpeers);
        if (!aggregate_set)
            aggregate_rate = brutal_group_aggregate_rate(&g->pacer);
        brutal_group_set_rule_config(&g->pacer, rate, gain, lock,
                                     aggregate_rate);
    }
    mutex_unlock(&bn->rules_mutex);
    return 0;
}

static int brutal_rule_del(struct brutal_net *bn, char *args)
{
    struct brutal_rule key = {}, *r;
    char *tok = strsep(&args, " ");
    int ret;

    if (!tok || (ret = brutal_parse_prefix(tok, &key)))
        return tok ? ret : -EINVAL;

    mutex_lock(&bn->rules_mutex);
    r = brutal_rule_find(bn, &key);
    if (r)
        brutal_rule_unpublish(bn, r);
    mutex_unlock(&bn->rules_mutex);
    if (!r)
        return -ENOENT;
    brutal_rule_free(r);
    return 0;
}

static void brutal_rules_flush(struct brutal_net *bn)
{
    LIST_HEAD(free_list);
    struct brutal_rule *r, *tmp;

    mutex_lock(&bn->rules_mutex);
    list_for_each_entry_safe(r, tmp, &bn->rules, list)
    {
        brutal_rule_unpublish(bn, r);
        list_add_tail(&r->free_list, &free_list);
    }
    mutex_unlock(&bn->rules_mutex);
    if (list_empty(&free_list))
        return;

    synchronize_rcu();
    list_for_each_entry_safe(r, tmp, &free_list, free_list)
    {
        list_del(&r->free_list);
        brutal_group_release_fallbacks(r->group);
        brutal_group_put(r->group);
        kfree(r);
    }
}

static int brutal_rules_show(struct seq_file *m, void *v)
{
    struct brutal_net *bn = brutal_pernet(m->private);
    struct brutal_rule *r;

    rcu_read_lock();
    list_for_each_entry_rcu(r, &bn->rules, list)
    {
        struct brutal_group *g = r->group;
        u64 rate;
        u32 gain;
        bool locked;
        u64 aggregate_rate;

        brutal_group_get_config(&g->pacer, &rate, &gain, &locked, NULL);
        aggregate_rate = brutal_group_aggregate_rate(&g->pacer);
        if (r->family == AF_INET)
            seq_printf(m, "dst=%pI4/%u", &r->v4, r->plen);
        else
            seq_printf(m, "dst=%pI6c/%u", &r->v6, r->plen);
        seq_printf(m, " rate=%llu gain=%u lock=%u group=%s id=%llu members=%u ips=%u sent=%llu",
                   rate, gain, locked, r->perip ? "perip" : "shared", g->id,
                   atomic_read(&g->pacer.members), atomic_read(&g->ip_groups),
                   brutal_group_sent(g));
        if (r->perip && g->rule_stats)
            seq_printf(m, " aggregate=%llu maxpeers=%u peer_slots=%d peak_peer_slots=%d budget_fallbacks=%lld",
                       aggregate_rate,
                       READ_ONCE(g->rule_stats->max_peers),
                       atomic_read(&g->rule_stats->peer_slots),
                       atomic_read(&g->rule_stats->peak_peer_slots),
                       atomic64_read(&g->rule_stats->peer_budget_fallbacks));
        seq_putc(m, '\n');
    }
    rcu_read_unlock();
    return 0;
}

static int brutal_rules_open(struct inode *inode, struct file *file)
{
    return single_open(file, brutal_rules_show, pde_data(inode));
}

static ssize_t brutal_rules_write(struct file *file, const char __user *ubuf,
                                  size_t len, loff_t *off)
{
    struct net *net = pde_data(file_inode(file));
    struct brutal_net *bn = brutal_pernet(net);
    char *buf, *args, *cmd;
    int ret;

    if (len > RULES_MAX_CMD_LEN)
        return -EINVAL;
    buf = memdup_user_nul(ubuf, len);
    if (IS_ERR(buf))
        return PTR_ERR(buf);

    args = strim(buf);
    cmd = strsep(&args, " ");
    if (!strcmp(cmd, "add"))
        ret = brutal_rule_add(bn, args);
    else if (!strcmp(cmd, "del"))
        ret = brutal_rule_del(bn, args);
    else if (!strcmp(cmd, "flush"))
        ret = (brutal_rules_flush(bn), 0);
    else
        ret = -EINVAL;

    kfree(buf);
    return ret ?: len;
}

static const struct proc_ops brutal_rules_proc_ops = {
    .proc_open = brutal_rules_open,
    .proc_read = seq_read,
    .proc_write = brutal_rules_write,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};

static struct brutal_group *
brutal_peers_next_group(struct brutal_net *bn, u64 after_id)
{
    unsigned long id;
    struct brutal_rule *r = NULL;
    struct brutal_group *g = NULL;

    if (after_id >= ULONG_MAX)
        return NULL;
    id = after_id;
    rcu_read_lock();
    for (;;)
    {
        r = xa_find_after(&bn->rules_by_id, &id, ULONG_MAX, XA_PRESENT);
        if (!r || r->perip)
            break;
    }
    if (r)
    {
        brutal_pacer_get(&r->group->pacer);
        g = r->group;
    }
    rcu_read_unlock();
    return g;
}

static void brutal_peers_pause(struct brutal_peers_seq *ctx)
{
    if (ctx->iter_started)
    {
        rhashtable_walk_stop(&ctx->iter);
        ctx->iter_started = false;
    }
}

static void brutal_peers_close_group(struct brutal_peers_seq *ctx)
{
    brutal_peers_pause(ctx);
    if (ctx->iter_entered)
    {
        rhashtable_walk_exit(&ctx->iter);
        ctx->iter_entered = false;
    }
    if (ctx->group)
    {
        brutal_group_put(ctx->group);
        ctx->group = NULL;
    }
}

static void brutal_peers_reset(struct brutal_peers_seq *ctx)
{
    if (ctx->peer)
    {
        brutal_pacer_put(&ctx->peer->pacer);
        ctx->peer = NULL;
    }
    brutal_peers_close_group(ctx);
    ctx->rule_id = 0;
    ctx->index = -1;
}

static bool brutal_peers_open_group(struct brutal_peers_seq *ctx)
{
    struct brutal_net *bn = brutal_pernet(ctx->net);
    struct brutal_rule_stats *stats;

    for (;;)
    {
        ctx->group = brutal_peers_next_group(bn, ctx->rule_id);
        if (!ctx->group)
            return false;
        ctx->rule_id = ctx->group->id;
        stats = READ_ONCE(ctx->group->rule_stats);
        if (stats && stats->peers_initialized)
            break;
        brutal_group_put(ctx->group);
        ctx->group = NULL;
    }

    rhashtable_walk_enter(&stats->peers, &ctx->iter);
    ctx->iter_entered = true;
    rhashtable_walk_start(&ctx->iter);
    ctx->iter_started = true;
    return true;
}

static void brutal_peers_resume(struct brutal_peers_seq *ctx)
{
    if (ctx->iter_entered && !ctx->iter_started)
    {
        rhashtable_walk_start(&ctx->iter);
        ctx->iter_started = true;
    }
}

static struct brutal_peer *brutal_peers_advance(struct brutal_peers_seq *ctx)
{
    struct brutal_peer *peer;

    if (ctx->peer)
    {
        brutal_pacer_put(&ctx->peer->pacer);
        ctx->peer = NULL;
    }

    for (;;)
    {
        if (!ctx->group && !brutal_peers_open_group(ctx))
            return NULL;
        brutal_peers_resume(ctx);

        peer = rhashtable_walk_next(&ctx->iter);
        if (IS_ERR(peer))
        {
            if (PTR_ERR(peer) == -EAGAIN)
                continue;
            brutal_peers_close_group(ctx);
            continue;
        }
        if (!peer)
        {
            brutal_peers_close_group(ctx);
            continue;
        }
        if (!brutal_peer_try_get(peer))
            continue;
        if (!atomic_read(&peer->pacer.members))
        {
            brutal_pacer_put(&peer->pacer);
            continue;
        }

        ctx->peer = peer;
        ctx->index++;
        return peer;
    }
}

static void *brutal_peers_seq_start(struct seq_file *m, loff_t *pos)
{
    struct brutal_peers_seq *ctx = m->private;

    if (*pos < 0)
        return NULL;
    if (ctx->peer && ctx->index == *pos)
    {
        brutal_peers_resume(ctx);
        return ctx->peer;
    }
    if (*pos <= ctx->index)
        brutal_peers_reset(ctx);

    while (ctx->index < *pos)
    {
        if (!brutal_peers_advance(ctx))
            return NULL;
    }
    brutal_peers_resume(ctx);
    return ctx->peer;
}

static void *brutal_peers_seq_next(struct seq_file *m, void *v, loff_t *pos)
{
    struct brutal_peers_seq *ctx = m->private;

    ++*pos;
    return brutal_peers_advance(ctx);
}

static void brutal_peers_seq_stop(struct seq_file *m, void *v)
{
    struct brutal_peers_seq *ctx = m->private;

    brutal_peers_pause(ctx);
}

static int brutal_peers_seq_show(struct seq_file *m, void *v)
{
    struct brutal_peers_seq *ctx = m->private;
    struct brutal_peer *peer = v;
    u64 rate;
    u32 gain;

    brutal_group_get_config(&peer->pacer, &rate, &gain, NULL, NULL);
    if (peer->key.family == AF_INET)
        seq_printf(m, "ip=%pI4 family=4", &peer->key.v4);
    else
        seq_printf(m, "ip=%pI6c family=6", &peer->key.v6);
    seq_printf(m, " rule=%llu rate=%llu gain=%u members=%u sent=%llu\n",
               ctx->group->id, rate, gain,
               atomic_read(&peer->pacer.members),
               atomic64_read(&peer->pacer.sent_bytes));
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
    struct brutal_peers_seq *ctx;
    int ret;

    ret = seq_open_private(file, &brutal_peers_seq_ops, sizeof(*ctx));
    if (ret)
        return ret;
    m = file->private_data;
    ctx = m->private;
    ctx->net = get_net(pde_data(inode));
    ctx->index = -1;
    return 0;
}

static int brutal_peers_release(struct inode *inode, struct file *file)
{
    struct seq_file *m = file->private_data;
    struct brutal_peers_seq *ctx = m->private;

    brutal_peers_reset(ctx);
    put_net(ctx->net);
    return seq_release_private(inode, file);
}

static const struct proc_ops brutal_peers_proc_ops = {
    .proc_open = brutal_peers_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = brutal_peers_release,
};

static int brutal_stats_show(struct seq_file *m, void *v)
{
    struct brutal_net *bn = brutal_pernet(m->private);

    seq_printf(m, "peer_alloc_failures=%lld\n",
               atomic64_read(&bn->peer_alloc_failures));
    seq_printf(m, "peer_insert_failures=%lld\n",
               atomic64_read(&bn->peer_insert_failures));
    seq_printf(m, "peer_fallback_connections=%lld\n",
               atomic64_read(&bn->peer_fallback_connections));
    seq_printf(m, "peer_budget_fallbacks=%lld\n",
               atomic64_read(&bn->peer_budget_fallbacks));
    seq_printf(m, "peer_slots=%d\n", atomic_read(&bn->peer_slots));
    seq_printf(m, "peak_peer_slots=%d\n", atomic_read(&bn->peak_peer_slots));
    seq_printf(m, "max_peers=%u\n", READ_ONCE(bn->max_peers));
    seq_printf(m, "active_peer_groups=%d\n", atomic_read(&bn->active_peers));
    seq_printf(m, "peak_peer_groups=%d\n", atomic_read(&bn->peak_peers));
    return 0;
}

static int brutal_limits_show(struct seq_file *m, void *v)
{
    struct brutal_net *bn = brutal_pernet(m->private);

    seq_printf(m, "max_peers=%u\n", READ_ONCE(bn->max_peers));
    seq_puts(m, "overflow=hashed_fallback\n");
    return 0;
}

static int brutal_limits_open(struct inode *inode, struct file *file)
{
    return single_open(file, brutal_limits_show, pde_data(inode));
}

static ssize_t brutal_limits_write(struct file *file, const char __user *ubuf,
                                   size_t len, loff_t *off)
{
    struct net *net = pde_data(file_inode(file));
    struct brutal_net *bn = brutal_pernet(net);
    char *buf, *value;
    u32 max_peers;
    int ret;

    if (!ns_capable(net->user_ns, CAP_NET_ADMIN))
        return -EPERM;
    if (!len || len > 64)
        return -EINVAL;
    buf = memdup_user_nul(ubuf, len);
    if (IS_ERR(buf))
        return PTR_ERR(buf);
    value = strim(buf);
    if (strncmp(value, "max_peers=", 10))
        ret = -EINVAL;
    else
        ret = kstrtou32(value + 10, 10, &max_peers);
    if (!ret && max_peers > INT_MAX)
        ret = -ERANGE;
    if (!ret)
    {
        mutex_lock(&bn->rules_mutex);
        WRITE_ONCE(bn->max_peers, max_peers);
        mutex_unlock(&bn->rules_mutex);
    }
    kfree(buf);
    return ret ?: len;
}

static const struct proc_ops brutal_limits_proc_ops = {
    .proc_open = brutal_limits_open,
    .proc_read = seq_read,
    .proc_write = brutal_limits_write,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};

static int brutal_version_show(struct seq_file *m, void *v)
{
    seq_printf(m, "version=%u.%u.%u\n", BRUTAL_VERSION_MAJOR,
               BRUTAL_VERSION_MINOR, BRUTAL_VERSION_PATCH);
    seq_printf(m, "abi=%u\n", BRUTAL_INFO_ABI_V1);
    seq_puts(m, "vendor=tcp-brutal-custom\n");
    seq_printf(m, "build=%.*s\n", BRUTAL_BUILD_ID_LEN, BRUTAL_BUILD_ID);
    seq_printf(m, "capabilities=0x%016llx\n",
               (unsigned long long)BRUTAL_CAPABILITIES);
    return 0;
}

static int __net_init brutal_net_init(struct net *net)
{
    struct brutal_net *bn = brutal_pernet(net);
    struct proc_dir_entry *dir;
    int ret;

    INIT_LIST_HEAD(&bn->rules);
    xa_init(&bn->rules_by_id);
    bitmap_zero(bn->v4_prefixes, 33);
    bitmap_zero(bn->v6_prefixes, 129);
    mutex_init(&bn->rules_mutex);
    atomic64_set(&bn->peer_alloc_failures, 0);
    atomic64_set(&bn->peer_insert_failures, 0);
    atomic64_set(&bn->peer_fallback_connections, 0);
    atomic64_set(&bn->peer_budget_fallbacks, 0);
    atomic_set(&bn->peer_slots, 0);
    atomic_set(&bn->peak_peer_slots, 0);
    atomic_set(&bn->active_peers, 0);
    atomic_set(&bn->peak_peers, 0);

    ret = rhashtable_init(&bn->exact_hosts, &brutal_exact_params);
    if (ret)
        return ret;
    ret = rhashtable_init(&bn->prefixes, &brutal_prefix_params);
    if (ret)
    {
        rhashtable_destroy(&bn->exact_hosts);
        return ret;
    }
    ret = rhashtable_init(&bn->app_groups, &brutal_app_params);
    if (ret)
    {
        rhashtable_destroy(&bn->prefixes);
        rhashtable_destroy(&bn->exact_hosts);
        return ret;
    }

    dir = proc_net_mkdir(net, "tcp_brutal", net->proc_net);
    if (!dir ||
        !proc_create_data("peers", 0444, dir, &brutal_peers_proc_ops, net) ||
        !proc_create_net_single("stats", 0444, dir, brutal_stats_show, NULL) ||
        !proc_create_data("limits", 0644, dir, &brutal_limits_proc_ops, net) ||
        !proc_create_net_single("version", 0444, dir, brutal_version_show, NULL) ||
        !proc_create_data("rules", 0644, dir, &brutal_rules_proc_ops, net))
    {
        remove_proc_subtree("tcp_brutal", net->proc_net);
        xa_destroy(&bn->rules_by_id);
        rhashtable_destroy(&bn->app_groups);
        rhashtable_destroy(&bn->prefixes);
        rhashtable_destroy(&bn->exact_hosts);
        return -ENOMEM;
    }
    return 0;
}

static void __net_exit brutal_net_exit(struct net *net)
{
    struct brutal_net *bn = brutal_pernet(net);

    brutal_rules_flush(bn);
    xa_destroy(&bn->rules_by_id);
    remove_proc_subtree("tcp_brutal", net->proc_net);
    rhashtable_destroy(&bn->app_groups);
    rhashtable_destroy(&bn->prefixes);
    rhashtable_destroy(&bn->exact_hosts);
}

static struct pernet_operations brutal_net_ops = {
    .id = &brutal_net_id,
    .size = sizeof(struct brutal_net),
    .init = brutal_net_init,
    .exit = brutal_net_exit,
};

int brutal_rules_init(void)
{
    return register_pernet_subsys(&brutal_net_ops);
}

void brutal_rules_exit(void)
{
    unregister_pernet_subsys(&brutal_net_ops);
}
