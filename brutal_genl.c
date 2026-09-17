// Typed control and observation API for TCP Brutal.
#include <linux/capability.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <net/genetlink.h>
#include "brutal.h"

static struct genl_family brutal_genl_family;
static bool brutal_genl_registered;
static DEFINE_MUTEX(brutal_genl_event_mutex);

static const struct nla_policy brutal_genl_policy[BRUTAL_A_MAX + 1] = {
    [BRUTAL_A_FAMILY] = {.type = NLA_U8},
    [BRUTAL_A_PREFIX_LEN] = {.type = NLA_U8},
    [BRUTAL_A_ADDRESS] = {.type = NLA_BINARY, .len = sizeof(struct in6_addr)},
    [BRUTAL_A_RULE_ID] = {.type = NLA_U64},
    [BRUTAL_A_RATE] = {.type = NLA_U64},
    [BRUTAL_A_AGGREGATE_RATE] = {.type = NLA_U64},
    [BRUTAL_A_CWND_GAIN] = {.type = NLA_U32},
    [BRUTAL_A_LOCKED] = {.type = NLA_U8},
    [BRUTAL_A_PERIP] = {.type = NLA_U8},
    [BRUTAL_A_MAX_PEERS] = {.type = NLA_U32},
    [BRUTAL_A_EVENT_TYPE] = {.type = NLA_U8},
};

enum
{
    BRUTAL_MCGRP_EVENTS,
};

static const struct genl_multicast_group brutal_genl_mcgrps[] = {
    [BRUTAL_MCGRP_EVENTS] = {.name = "events"},
};

static int brutal_genl_put_info(struct sk_buff *skb)
{
    if (nla_put_u16(skb, BRUTAL_A_ABI_VERSION, BRUTAL_INFO_ABI_V1) ||
        nla_put_u32(skb, BRUTAL_A_VENDOR_ID, BRUTAL_VENDOR_CUSTOM) ||
        nla_put_u32(skb, BRUTAL_A_VERSION, BRUTAL_VERSION) ||
        nla_put_u32(skb, BRUTAL_A_FLAGS, 0) ||
        nla_put_u64_64bit(skb, BRUTAL_A_CAPABILITIES, BRUTAL_CAPABILITIES,
                          BRUTAL_A_UNSPEC) ||
        nla_put(skb, BRUTAL_A_BUILD_ID, BRUTAL_BUILD_ID_LEN,
                BRUTAL_BUILD_ID))
        return -EMSGSIZE;
    return 0;
}

static int brutal_genl_put_rule(struct sk_buff *skb,
                                const struct brutal_rule_info *rule)
{
    const void *address = rule->family == AF_INET ? (const void *)&rule->v4
                                                   : (const void *)&rule->v6;
    int address_len = rule->family == AF_INET ? sizeof(rule->v4)
                                              : sizeof(rule->v6);

    if (nla_put_u8(skb, BRUTAL_A_FAMILY, rule->family) ||
        nla_put_u8(skb, BRUTAL_A_PREFIX_LEN, rule->plen) ||
        nla_put(skb, BRUTAL_A_ADDRESS, address_len, address) ||
        nla_put_u64_64bit(skb, BRUTAL_A_RULE_ID, rule->id,
                          BRUTAL_A_UNSPEC) ||
        nla_put_u64_64bit(skb, BRUTAL_A_RATE, rule->rate,
                          BRUTAL_A_UNSPEC) ||
        nla_put_u64_64bit(skb, BRUTAL_A_AGGREGATE_RATE,
                          rule->aggregate_rate, BRUTAL_A_UNSPEC) ||
        nla_put_u32(skb, BRUTAL_A_CWND_GAIN, rule->cwnd_gain) ||
        nla_put_u8(skb, BRUTAL_A_LOCKED, rule->locked) ||
        nla_put_u8(skb, BRUTAL_A_PERIP, rule->perip) ||
        nla_put_u32(skb, BRUTAL_A_MAX_PEERS, rule->max_peers) ||
        nla_put_u32(skb, BRUTAL_A_MEMBERS, rule->members) ||
        nla_put_u32(skb, BRUTAL_A_ACTIVE_PEERS, rule->active_peers) ||
        nla_put_u64_64bit(skb, BRUTAL_A_SENT_BYTES, rule->sent_bytes,
                          BRUTAL_A_UNSPEC))
        return -EMSGSIZE;
    return 0;
}

static int brutal_genl_reply(struct genl_info *info, u8 command,
                             int (*fill)(struct sk_buff *skb, void *arg),
                             void *arg)
{
    struct sk_buff *reply;
    void *header;
    int ret;

    reply = genlmsg_new(GENLMSG_DEFAULT_SIZE, GFP_KERNEL);
    if (!reply)
        return -ENOMEM;
    header = genlmsg_put_reply(reply, info, &brutal_genl_family, 0, command);
    if (!header)
    {
        nlmsg_free(reply);
        return -EMSGSIZE;
    }
    ret = fill(reply, arg);
    if (ret)
    {
        genlmsg_cancel(reply, header);
        nlmsg_free(reply);
        return ret;
    }
    genlmsg_end(reply, header);
    return genlmsg_reply(reply, info);
}

static int brutal_genl_fill_info(struct sk_buff *skb, void *arg)
{
    return brutal_genl_put_info(skb);
}

static int brutal_genl_get_info(struct sk_buff *skb, struct genl_info *info)
{
    return brutal_genl_reply(info, BRUTAL_CMD_GET_INFO, brutal_genl_fill_info,
                             NULL);
}

static int brutal_genl_fill_stats(struct sk_buff *skb, void *arg)
{
    const struct brutal_net_stats_info *stats = arg;

    if (nla_put_u64_64bit(skb, BRUTAL_A_PEER_ALLOC_FAILURES,
                          stats->peer_alloc_failures, BRUTAL_A_UNSPEC) ||
        nla_put_u64_64bit(skb, BRUTAL_A_PEER_INSERT_FAILURES,
                          stats->peer_insert_failures, BRUTAL_A_UNSPEC) ||
        nla_put_u64_64bit(skb, BRUTAL_A_PEER_FALLBACKS,
                          stats->peer_fallbacks, BRUTAL_A_UNSPEC) ||
        nla_put_u64_64bit(skb, BRUTAL_A_PEER_BUDGET_FALLBACKS,
                          stats->peer_budget_fallbacks, BRUTAL_A_UNSPEC) ||
        nla_put_u32(skb, BRUTAL_A_PEER_SLOTS, stats->peer_slots) ||
        nla_put_u32(skb, BRUTAL_A_PEAK_PEER_SLOTS,
                    stats->peak_peer_slots) ||
        nla_put_u32(skb, BRUTAL_A_ACTIVE_PEERS, stats->active_peers) ||
        nla_put_u32(skb, BRUTAL_A_PEAK_PEERS, stats->peak_peers) ||
        nla_put_u32(skb, BRUTAL_A_MAX_PEERS, stats->max_peers))
        return -EMSGSIZE;
    return 0;
}

static int brutal_genl_get_stats(struct sk_buff *skb, struct genl_info *info)
{
    struct brutal_net_stats_info stats;

    brutal_net_stats_get(genl_info_net(info), &stats);
    return brutal_genl_reply(info, BRUTAL_CMD_GET_STATS,
                             brutal_genl_fill_stats, &stats);
}

static int brutal_genl_fill_rule(struct sk_buff *skb, void *arg)
{
    return brutal_genl_put_rule(skb, arg);
}

static int brutal_genl_rule_get(struct sk_buff *skb, struct genl_info *info)
{
    struct brutal_rule_info rule;
    u64 id;

    if (!info->attrs[BRUTAL_A_RULE_ID])
        return -EINVAL;
    id = nla_get_u64(info->attrs[BRUTAL_A_RULE_ID]);
    if (id > ULONG_MAX || !brutal_rule_info_get(genl_info_net(info), id, &rule))
        return -ENOENT;
    return brutal_genl_reply(info, BRUTAL_CMD_RULE_GET,
                             brutal_genl_fill_rule, &rule);
}

static int brutal_genl_rule_dump(struct sk_buff *skb,
                                 struct netlink_callback *cb)
{
    struct net *net = sock_net(cb->skb->sk);
    unsigned long id = cb->args[0];
    struct brutal_rule_info rule;
    int count = 0;

    while (brutal_rule_info_next(net, &id, &rule))
    {
        void *header = genlmsg_put(skb, NETLINK_CB(cb->skb).portid,
                                   cb->nlh->nlmsg_seq, &brutal_genl_family,
                                   NLM_F_MULTI, BRUTAL_CMD_RULE_DUMP);

        if (!header)
            break;
        if (brutal_genl_put_rule(skb, &rule))
        {
            genlmsg_cancel(skb, header);
            break;
        }
        genlmsg_end(skb, header);
        cb->args[0] = id;
        count++;
    }
    return count ? skb->len : 0;
}

static int brutal_genl_parse_rule(struct genl_info *info,
                                  struct brutal_rule_info *rule)
{
    struct nlattr *address = info->attrs[BRUTAL_A_ADDRESS];

    if (!info->attrs[BRUTAL_A_FAMILY] ||
        !info->attrs[BRUTAL_A_PREFIX_LEN] || !address ||
        !info->attrs[BRUTAL_A_RATE])
        return -EINVAL;
    memset(rule, 0, sizeof(*rule));
    rule->family = nla_get_u8(info->attrs[BRUTAL_A_FAMILY]);
    rule->plen = nla_get_u8(info->attrs[BRUTAL_A_PREFIX_LEN]);
    if (rule->family == AF_INET && rule->plen <= 32 &&
        nla_len(address) == sizeof(rule->v4))
        memcpy(&rule->v4, nla_data(address), sizeof(rule->v4));
    else if (rule->family == AF_INET6 && rule->plen <= 128 &&
             nla_len(address) == sizeof(rule->v6))
        memcpy(&rule->v6, nla_data(address), sizeof(rule->v6));
    else
        return -EINVAL;
    rule->rate = nla_get_u64(info->attrs[BRUTAL_A_RATE]);
    rule->cwnd_gain = info->attrs[BRUTAL_A_CWND_GAIN]
                          ? nla_get_u32(info->attrs[BRUTAL_A_CWND_GAIN])
                          : INIT_CWND_GAIN;
    rule->locked = !info->attrs[BRUTAL_A_LOCKED] ||
                   nla_get_u8(info->attrs[BRUTAL_A_LOCKED]);
    rule->perip = info->attrs[BRUTAL_A_PERIP] &&
                  nla_get_u8(info->attrs[BRUTAL_A_PERIP]);
    if (info->attrs[BRUTAL_A_AGGREGATE_RATE])
    {
        rule->aggregate_rate =
            nla_get_u64(info->attrs[BRUTAL_A_AGGREGATE_RATE]);
        rule->aggregate_set = true;
    }
    if (info->attrs[BRUTAL_A_MAX_PEERS])
    {
        rule->max_peers = nla_get_u32(info->attrs[BRUTAL_A_MAX_PEERS]);
        rule->max_peers_set = true;
    }
    return 0;
}

static int brutal_genl_rule_add(struct sk_buff *skb, struct genl_info *info)
{
    struct brutal_rule_info rule;
    int ret;

    if (!ns_capable(genl_info_net(info)->user_ns, CAP_NET_ADMIN))
        return -EPERM;
    ret = brutal_genl_parse_rule(info, &rule);
    return ret ?: brutal_rule_configure(genl_info_net(info), &rule);
}

static int brutal_genl_rule_del(struct sk_buff *skb, struct genl_info *info)
{
    struct brutal_rule_info rule;

    if (!ns_capable(genl_info_net(info)->user_ns, CAP_NET_ADMIN))
        return -EPERM;
    if (!info->attrs[BRUTAL_A_FAMILY] ||
        !info->attrs[BRUTAL_A_PREFIX_LEN] ||
        !info->attrs[BRUTAL_A_ADDRESS])
        return -EINVAL;
    memset(&rule, 0, sizeof(rule));
    rule.family = nla_get_u8(info->attrs[BRUTAL_A_FAMILY]);
    rule.plen = nla_get_u8(info->attrs[BRUTAL_A_PREFIX_LEN]);
    if (rule.family == AF_INET && rule.plen <= 32 &&
        nla_len(info->attrs[BRUTAL_A_ADDRESS]) == sizeof(rule.v4))
        memcpy(&rule.v4, nla_data(info->attrs[BRUTAL_A_ADDRESS]),
               sizeof(rule.v4));
    else if (rule.family == AF_INET6 && rule.plen <= 128 &&
             nla_len(info->attrs[BRUTAL_A_ADDRESS]) == sizeof(rule.v6))
        memcpy(&rule.v6, nla_data(info->attrs[BRUTAL_A_ADDRESS]),
               sizeof(rule.v6));
    else
        return -EINVAL;
    return brutal_rule_delete(genl_info_net(info), &rule);
}

static int brutal_genl_fill_limit(struct sk_buff *skb, void *arg)
{
    u32 max_peers = *(u32 *)arg;

    if (nla_put_u32(skb, BRUTAL_A_MAX_PEERS, max_peers) ||
        nla_put_u8(skb, BRUTAL_A_OVERFLOW_POLICY,
                   BRUTAL_OVERFLOW_HASHED_FALLBACK))
        return -EMSGSIZE;
    return 0;
}

static int brutal_genl_limit_get(struct sk_buff *skb, struct genl_info *info)
{
    u32 max_peers = brutal_net_limit_get(genl_info_net(info));

    return brutal_genl_reply(info, BRUTAL_CMD_LIMIT_GET,
                             brutal_genl_fill_limit, &max_peers);
}

static int brutal_genl_limit_set(struct sk_buff *skb, struct genl_info *info)
{
    if (!ns_capable(genl_info_net(info)->user_ns, CAP_NET_ADMIN))
        return -EPERM;
    if (!info->attrs[BRUTAL_A_MAX_PEERS])
        return -EINVAL;
    return brutal_net_limit_set(
        genl_info_net(info), nla_get_u32(info->attrs[BRUTAL_A_MAX_PEERS]));
}

static int brutal_genl_put_peer(struct sk_buff *skb,
                                const struct brutal_peer_info *peer)
{
    const void *address = peer->key.family == AF_INET
                              ? (const void *)&peer->key.v4
                              : (const void *)&peer->key.v6;
    int address_len = peer->key.family == AF_INET ? sizeof(peer->key.v4)
                                                  : sizeof(peer->key.v6);

    if (nla_put_u8(skb, BRUTAL_A_FAMILY, peer->key.family) ||
        nla_put(skb, BRUTAL_A_ADDRESS, address_len, address) ||
        nla_put_u64_64bit(skb, BRUTAL_A_RULE_ID, peer->rule_id,
                          BRUTAL_A_UNSPEC) ||
        nla_put_u64_64bit(skb, BRUTAL_A_RATE, peer->rate,
                          BRUTAL_A_UNSPEC) ||
        nla_put_u32(skb, BRUTAL_A_CWND_GAIN, peer->cwnd_gain) ||
        nla_put_u32(skb, BRUTAL_A_MEMBERS, peer->members) ||
        nla_put_u64_64bit(skb, BRUTAL_A_SENT_BYTES, peer->sent_bytes,
                          BRUTAL_A_UNSPEC))
        return -EMSGSIZE;
    return 0;
}

static int brutal_genl_fill_peer(struct sk_buff *skb, void *arg)
{
    return brutal_genl_put_peer(skb, arg);
}

static bool brutal_genl_peer_matches(const struct brutal_peer_info *peer,
                                     struct genl_info *info)
{
    struct nlattr *address = info->attrs[BRUTAL_A_ADDRESS];
    u8 family;

    if (!info->attrs[BRUTAL_A_RULE_ID] ||
        !info->attrs[BRUTAL_A_FAMILY] || !address ||
        peer->rule_id != nla_get_u64(info->attrs[BRUTAL_A_RULE_ID]))
        return false;
    family = nla_get_u8(info->attrs[BRUTAL_A_FAMILY]);
    if (family != peer->key.family)
        return false;
    if (family == AF_INET)
        return nla_len(address) == sizeof(peer->key.v4) &&
               !memcmp(nla_data(address), &peer->key.v4,
                       sizeof(peer->key.v4));
    return family == AF_INET6 &&
           nla_len(address) == sizeof(peer->key.v6) &&
           !memcmp(nla_data(address), &peer->key.v6,
                   sizeof(peer->key.v6));
}

static int brutal_genl_peer_get(struct sk_buff *skb, struct genl_info *info)
{
    struct brutal_peer_iter iter;
    struct brutal_peer_info peer;
    int ret = -ENOENT;

    brutal_peer_iter_init(&iter, genl_info_net(info));
    while (brutal_peer_iter_next(&iter, &peer))
    {
        if (!brutal_genl_peer_matches(&peer, info))
            continue;
        ret = brutal_genl_reply(info, BRUTAL_CMD_PEER_GET,
                                brutal_genl_fill_peer, &peer);
        break;
    }
    brutal_peer_iter_fini(&iter);
    return ret;
}

struct brutal_genl_peer_dump_ctx
{
    struct brutal_peer_iter iter;
    struct brutal_peer_info peer;
    bool pending;
};

static int brutal_genl_peer_dump_start(struct netlink_callback *cb)
{
    struct brutal_genl_peer_dump_ctx *ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);

    if (!ctx)
        return -ENOMEM;
    brutal_peer_iter_init(&ctx->iter, sock_net(cb->skb->sk));
    cb->args[0] = (long)ctx;
    return 0;
}

static int brutal_genl_peer_dump(struct sk_buff *skb,
                                 struct netlink_callback *cb)
{
    struct brutal_genl_peer_dump_ctx *ctx = (void *)cb->args[0];
    int count = 0;

    for (;;)
    {
        void *header;

        if (!ctx->pending)
        {
            if (!brutal_peer_iter_next(&ctx->iter, &ctx->peer))
                break;
            ctx->pending = true;
        }
        header = genlmsg_put(skb, NETLINK_CB(cb->skb).portid,
                             cb->nlh->nlmsg_seq, &brutal_genl_family,
                             NLM_F_MULTI, BRUTAL_CMD_PEER_DUMP);
        if (!header)
            break;
        if (brutal_genl_put_peer(skb, &ctx->peer))
        {
            genlmsg_cancel(skb, header);
            break;
        }
        genlmsg_end(skb, header);
        ctx->pending = false;
        count++;
    }
    return count ? skb->len : 0;
}

static int brutal_genl_peer_dump_done(struct netlink_callback *cb)
{
    struct brutal_genl_peer_dump_ctx *ctx = (void *)cb->args[0];

    if (ctx)
    {
        brutal_peer_iter_fini(&ctx->iter);
        kfree(ctx);
    }
    return 0;
}

static const struct genl_ops brutal_genl_ops[] = {
    {.cmd = BRUTAL_CMD_GET_INFO, .doit = brutal_genl_get_info},
    {.cmd = BRUTAL_CMD_GET_STATS, .doit = brutal_genl_get_stats},
    {.cmd = BRUTAL_CMD_RULE_GET, .doit = brutal_genl_rule_get},
    {.cmd = BRUTAL_CMD_RULE_DUMP, .dumpit = brutal_genl_rule_dump},
    {.cmd = BRUTAL_CMD_RULE_ADD, .doit = brutal_genl_rule_add},
    {.cmd = BRUTAL_CMD_RULE_DEL, .doit = brutal_genl_rule_del},
    {.cmd = BRUTAL_CMD_PEER_GET, .doit = brutal_genl_peer_get},
    {.cmd = BRUTAL_CMD_PEER_DUMP,
     .start = brutal_genl_peer_dump_start,
     .dumpit = brutal_genl_peer_dump,
     .done = brutal_genl_peer_dump_done},
    {.cmd = BRUTAL_CMD_LIMIT_GET, .doit = brutal_genl_limit_get},
    {.cmd = BRUTAL_CMD_LIMIT_SET, .doit = brutal_genl_limit_set},
};

static struct genl_family brutal_genl_family = {
    .name = BRUTAL_GENL_NAME,
    .version = BRUTAL_GENL_VERSION,
    .maxattr = BRUTAL_A_MAX,
    .policy = brutal_genl_policy,
    .netnsok = true,
    .module = THIS_MODULE,
    .ops = brutal_genl_ops,
    .n_ops = ARRAY_SIZE(brutal_genl_ops),
    .mcgrps = brutal_genl_mcgrps,
    .n_mcgrps = ARRAY_SIZE(brutal_genl_mcgrps),
};

static void brutal_genl_event_send(struct net *net, u8 event,
                                   const struct brutal_rule_info *rule,
                                   const u32 *max_peers)
{
    struct sk_buff *skb;
    void *header;

    mutex_lock(&brutal_genl_event_mutex);
    if (!brutal_genl_registered)
    {
        mutex_unlock(&brutal_genl_event_mutex);
        return;
    }
    skb = genlmsg_new(GENLMSG_DEFAULT_SIZE, GFP_KERNEL);
    if (!skb)
    {
        mutex_unlock(&brutal_genl_event_mutex);
        return;
    }
    header = genlmsg_put(skb, 0, 0, &brutal_genl_family, 0,
                         BRUTAL_CMD_EVENT);
    if (!header || nla_put_u8(skb, BRUTAL_A_EVENT_TYPE, event) ||
        (rule && brutal_genl_put_rule(skb, rule)) ||
        (max_peers && nla_put_u32(skb, BRUTAL_A_MAX_PEERS, *max_peers)))
    {
        if (header)
            genlmsg_cancel(skb, header);
        nlmsg_free(skb);
        mutex_unlock(&brutal_genl_event_mutex);
        return;
    }
    genlmsg_end(skb, header);
    genlmsg_multicast_netns(&brutal_genl_family, net, skb, 0,
                            BRUTAL_MCGRP_EVENTS, GFP_KERNEL);
    mutex_unlock(&brutal_genl_event_mutex);
}

void brutal_genl_rule_event(struct net *net, u8 event,
                            const struct brutal_rule_info *rule)
{
    brutal_genl_event_send(net, event, rule, NULL);
}

void brutal_genl_limit_event(struct net *net, u32 max_peers)
{
    brutal_genl_event_send(net, BRUTAL_EVENT_LIMIT_CHANGED, NULL,
                           &max_peers);
}

int brutal_genl_init(void)
{
    int ret = genl_register_family(&brutal_genl_family);

    if (!ret)
    {
        mutex_lock(&brutal_genl_event_mutex);
        brutal_genl_registered = true;
        mutex_unlock(&brutal_genl_event_mutex);
    }
    return ret;
}

void brutal_genl_exit(void)
{
    mutex_lock(&brutal_genl_event_mutex);
    brutal_genl_registered = false;
    mutex_unlock(&brutal_genl_event_mutex);
    genl_unregister_family(&brutal_genl_family);
}
