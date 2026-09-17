#ifndef BRUTAL_NETLINK_H
#define BRUTAL_NETLINK_H

#include <netinet/in.h>
#include <stdint.h>

struct brutal_nl_rule
{
    uint8_t family;
    uint8_t plen;
    uint8_t locked;
    uint8_t perip;
    uint8_t aggregate_set;
    uint8_t max_peers_set;
    union
    {
        struct in_addr v4;
        struct in6_addr v6;
    } address;
    uint64_t id;
    uint64_t rate;
    uint64_t aggregate_rate;
    uint64_t sent_bytes;
    uint32_t cwnd_gain;
    uint32_t max_peers;
    uint32_t members;
    uint32_t active_peers;
};

struct brutal_nl_peer
{
    uint8_t family;
    union
    {
        struct in_addr v4;
        struct in6_addr v6;
    } address;
    uint64_t rule_id;
    uint64_t rate;
    uint64_t sent_bytes;
    uint32_t cwnd_gain;
    uint32_t members;
};

struct brutal_nl_stats
{
    uint64_t peer_alloc_failures;
    uint64_t peer_insert_failures;
    uint64_t peer_fallbacks;
    uint64_t peer_budget_fallbacks;
    uint32_t peer_slots;
    uint32_t peak_peer_slots;
    uint32_t active_peers;
    uint32_t peak_peers;
    uint32_t max_peers;
};

typedef int (*brutal_nl_rule_cb)(const struct brutal_nl_rule *, void *);
typedef int (*brutal_nl_peer_cb)(const struct brutal_nl_peer *, void *);

int brutal_nl_available(void);
int brutal_nl_rule_dump(brutal_nl_rule_cb callback, void *arg);
int brutal_nl_peer_dump(brutal_nl_peer_cb callback, void *arg);
int brutal_nl_rule_add(const struct brutal_nl_rule *rule);
int brutal_nl_rule_del(const struct brutal_nl_rule *rule);
int brutal_nl_stats_get(struct brutal_nl_stats *stats);
int brutal_nl_limit_get(uint32_t *max_peers);
int brutal_nl_limit_set(uint32_t max_peers);

#endif
