#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "../brutal_uapi.h"
#include "brutal_netlink.h"

struct brutal_nl_request
{
    struct nlmsghdr nlh;
    struct genlmsghdr genl;
    unsigned char attrs[512];
};

typedef int (*brutal_nl_message_cb)(const struct nlmsghdr *, void *);

static uint32_t brutal_nl_sequence;

static void *brutal_nla_data(const struct nlattr *attr)
{
    return (unsigned char *)attr + NLA_HDRLEN;
}

static int brutal_nla_put(struct brutal_nl_request *request, uint16_t type,
                          const void *data, size_t size)
{
    size_t aligned = NLA_ALIGN(NLA_HDRLEN + size);
    struct nlattr *attr;

    if (request->nlh.nlmsg_len + aligned > sizeof(*request))
    {
        errno = EMSGSIZE;
        return -1;
    }
    attr = (struct nlattr *)((unsigned char *)request + request->nlh.nlmsg_len);
    attr->nla_type = type;
    attr->nla_len = NLA_HDRLEN + size;
    memcpy(brutal_nla_data(attr), data, size);
    memset((unsigned char *)attr + attr->nla_len, 0, aligned - attr->nla_len);
    request->nlh.nlmsg_len += aligned;
    return 0;
}

static struct nlattr *brutal_nla_find(const struct nlmsghdr *nlh,
                                      uint16_t type)
{
    const struct genlmsghdr *genl = NLMSG_DATA(nlh);
    int remaining = nlh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
    struct nlattr *attr = (struct nlattr *)((unsigned char *)genl + GENL_HDRLEN);

    while (remaining >= (int)sizeof(*attr) && attr->nla_len >= sizeof(*attr) &&
           attr->nla_len <= remaining)
    {
        if ((attr->nla_type & NLA_TYPE_MASK) == type)
            return attr;
        remaining -= NLA_ALIGN(attr->nla_len);
        attr = (struct nlattr *)((unsigned char *)attr + NLA_ALIGN(attr->nla_len));
    }
    return NULL;
}

static int brutal_nl_socket(void)
{
    struct sockaddr_nl address = {.nl_family = AF_NETLINK};
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);

    if (fd < 0)
        return -1;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)))
    {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    return fd;
}

static void brutal_nl_request_init(struct brutal_nl_request *request,
                                   uint16_t family, uint8_t command,
                                   uint16_t flags)
{
    memset(request, 0, sizeof(*request));
    request->nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
    request->nlh.nlmsg_type = family;
    request->nlh.nlmsg_flags = NLM_F_REQUEST | flags;
    request->nlh.nlmsg_seq = ++brutal_nl_sequence;
    request->genl.cmd = command;
    request->genl.version = BRUTAL_GENL_VERSION;
}

static int brutal_nl_exchange(int fd, struct brutal_nl_request *request,
                              brutal_nl_message_cb callback, void *arg)
{
    struct sockaddr_nl kernel = {.nl_family = AF_NETLINK};
    unsigned char buffer[65536];
    int dump = request->nlh.nlmsg_flags & NLM_F_DUMP;

    if (sendto(fd, request, request->nlh.nlmsg_len, 0,
               (struct sockaddr *)&kernel, sizeof(kernel)) < 0)
        return -1;
    for (;;)
    {
        ssize_t length = recv(fd, buffer, sizeof(buffer), 0);
        struct nlmsghdr *nlh;

        if (length < 0)
            return -1;
        for (nlh = (struct nlmsghdr *)buffer; NLMSG_OK(nlh, length);
             nlh = NLMSG_NEXT(nlh, length))
        {
            if (nlh->nlmsg_seq != request->nlh.nlmsg_seq)
                continue;
            if (nlh->nlmsg_type == NLMSG_DONE)
                return 0;
            if (nlh->nlmsg_type == NLMSG_ERROR)
            {
                const struct nlmsgerr *error = NLMSG_DATA(nlh);

                if (!error->error)
                    return 0;
                errno = -error->error;
                return -1;
            }
            if (callback && callback(nlh, arg))
                return -1;
            if (!dump)
                return 0;
        }
    }
}

static int brutal_nl_family_reply(const struct nlmsghdr *nlh, void *arg)
{
    struct nlattr *attr = brutal_nla_find(nlh, CTRL_ATTR_FAMILY_ID);

    if (!attr || attr->nla_len != NLA_HDRLEN + sizeof(uint16_t))
    {
        errno = EPROTO;
        return -1;
    }
    memcpy(arg, brutal_nla_data(attr), sizeof(uint16_t));
    return 0;
}

static int brutal_nl_resolve(int fd, uint16_t *family)
{
    struct brutal_nl_request request;
    const char name[] = BRUTAL_GENL_NAME;

    brutal_nl_request_init(&request, GENL_ID_CTRL, CTRL_CMD_GETFAMILY, 0);
    if (brutal_nla_put(&request, CTRL_ATTR_FAMILY_NAME, name, sizeof(name)))
        return -1;
    return brutal_nl_exchange(fd, &request, brutal_nl_family_reply, family);
}

static int brutal_nl_open(uint16_t *family)
{
    int fd = brutal_nl_socket();

    if (fd < 0)
        return -1;
    if (brutal_nl_resolve(fd, family))
    {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    return fd;
}

int brutal_nl_available(void)
{
    uint16_t family;
    int fd = brutal_nl_open(&family);

    if (fd < 0)
        return 0;
    close(fd);
    return 1;
}

static int brutal_nla_copy(const struct nlmsghdr *nlh, uint16_t type,
                           void *value, size_t size, int required)
{
    struct nlattr *attr = brutal_nla_find(nlh, type);

    if (!attr)
        return required ? -1 : 0;
    if (attr->nla_len != NLA_HDRLEN + size)
        return -1;
    memcpy(value, brutal_nla_data(attr), size);
    return 0;
}

struct brutal_nl_rule_dump_arg
{
    brutal_nl_rule_cb callback;
    void *arg;
};

static int brutal_nl_rule_reply(const struct nlmsghdr *nlh, void *arg)
{
    struct brutal_nl_rule_dump_arg *dump = arg;
    struct brutal_nl_rule rule;
    struct nlattr *address;

    memset(&rule, 0, sizeof(rule));
    if (brutal_nla_copy(nlh, BRUTAL_A_FAMILY, &rule.family,
                        sizeof(rule.family), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_PREFIX_LEN, &rule.plen,
                        sizeof(rule.plen), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_RULE_ID, &rule.id, sizeof(rule.id), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_RATE, &rule.rate, sizeof(rule.rate), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_AGGREGATE_RATE, &rule.aggregate_rate,
                        sizeof(rule.aggregate_rate), 0) ||
        brutal_nla_copy(nlh, BRUTAL_A_SENT_BYTES, &rule.sent_bytes,
                        sizeof(rule.sent_bytes), 0) ||
        brutal_nla_copy(nlh, BRUTAL_A_CWND_GAIN, &rule.cwnd_gain,
                        sizeof(rule.cwnd_gain), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_LOCKED, &rule.locked,
                        sizeof(rule.locked), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_PERIP, &rule.perip,
                        sizeof(rule.perip), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_MAX_PEERS, &rule.max_peers,
                        sizeof(rule.max_peers), 0) ||
        brutal_nla_copy(nlh, BRUTAL_A_MEMBERS, &rule.members,
                        sizeof(rule.members), 0) ||
        brutal_nla_copy(nlh, BRUTAL_A_ACTIVE_PEERS, &rule.active_peers,
                        sizeof(rule.active_peers), 0))
    {
        errno = EPROTO;
        return -1;
    }
    address = brutal_nla_find(nlh, BRUTAL_A_ADDRESS);
    if (!address ||
        (rule.family == AF_INET &&
         brutal_nla_copy(nlh, BRUTAL_A_ADDRESS, &rule.address.v4,
                         sizeof(rule.address.v4), 1)) ||
        (rule.family == AF_INET6 &&
         brutal_nla_copy(nlh, BRUTAL_A_ADDRESS, &rule.address.v6,
                         sizeof(rule.address.v6), 1)) ||
        (rule.family != AF_INET && rule.family != AF_INET6))
    {
        errno = EPROTO;
        return -1;
    }
    return dump->callback(&rule, dump->arg);
}

int brutal_nl_rule_dump(brutal_nl_rule_cb callback, void *arg)
{
    struct brutal_nl_rule_dump_arg dump = {.callback = callback, .arg = arg};
    struct brutal_nl_request request;
    uint16_t family;
    int fd = brutal_nl_open(&family);
    int ret;

    if (fd < 0)
        return -1;
    brutal_nl_request_init(&request, family, BRUTAL_CMD_RULE_DUMP, NLM_F_DUMP);
    ret = brutal_nl_exchange(fd, &request, brutal_nl_rule_reply, &dump);
    close(fd);
    return ret;
}

struct brutal_nl_peer_dump_arg
{
    brutal_nl_peer_cb callback;
    void *arg;
};

static int brutal_nl_peer_reply(const struct nlmsghdr *nlh, void *arg)
{
    struct brutal_nl_peer_dump_arg *dump = arg;
    struct brutal_nl_peer peer;

    memset(&peer, 0, sizeof(peer));
    if (brutal_nla_copy(nlh, BRUTAL_A_FAMILY, &peer.family,
                        sizeof(peer.family), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_RULE_ID, &peer.rule_id,
                        sizeof(peer.rule_id), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_RATE, &peer.rate,
                        sizeof(peer.rate), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_SENT_BYTES, &peer.sent_bytes,
                        sizeof(peer.sent_bytes), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_CWND_GAIN, &peer.cwnd_gain,
                        sizeof(peer.cwnd_gain), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_MEMBERS, &peer.members,
                        sizeof(peer.members), 1) ||
        (peer.family == AF_INET &&
         brutal_nla_copy(nlh, BRUTAL_A_ADDRESS, &peer.address.v4,
                         sizeof(peer.address.v4), 1)) ||
        (peer.family == AF_INET6 &&
         brutal_nla_copy(nlh, BRUTAL_A_ADDRESS, &peer.address.v6,
                         sizeof(peer.address.v6), 1)) ||
        (peer.family != AF_INET && peer.family != AF_INET6))
    {
        errno = EPROTO;
        return -1;
    }
    return dump->callback(&peer, dump->arg);
}

int brutal_nl_peer_dump(brutal_nl_peer_cb callback, void *arg)
{
    struct brutal_nl_peer_dump_arg dump = {.callback = callback, .arg = arg};
    struct brutal_nl_request request;
    uint16_t family;
    int fd = brutal_nl_open(&family);
    int ret;

    if (fd < 0)
        return -1;
    brutal_nl_request_init(&request, family, BRUTAL_CMD_PEER_DUMP, NLM_F_DUMP);
    ret = brutal_nl_exchange(fd, &request, brutal_nl_peer_reply, &dump);
    close(fd);
    return ret;
}

static int brutal_nl_rule_request(const struct brutal_nl_rule *rule,
                                  uint8_t command)
{
    struct brutal_nl_request request;
    const void *address;
    size_t address_len;
    uint16_t family;
    int fd = brutal_nl_open(&family);
    int ret;

    if (fd < 0)
        return -1;
    brutal_nl_request_init(&request, family, command, NLM_F_ACK);
    address = rule->family == AF_INET ? (const void *)&rule->address.v4
                                      : (const void *)&rule->address.v6;
    address_len = rule->family == AF_INET ? sizeof(rule->address.v4)
                                          : sizeof(rule->address.v6);
    if (brutal_nla_put(&request, BRUTAL_A_FAMILY, &rule->family,
                       sizeof(rule->family)) ||
        brutal_nla_put(&request, BRUTAL_A_PREFIX_LEN, &rule->plen,
                       sizeof(rule->plen)) ||
        brutal_nla_put(&request, BRUTAL_A_ADDRESS, address, address_len) ||
        (command == BRUTAL_CMD_RULE_ADD &&
         (brutal_nla_put(&request, BRUTAL_A_RATE, &rule->rate,
                         sizeof(rule->rate)) ||
          brutal_nla_put(&request, BRUTAL_A_CWND_GAIN, &rule->cwnd_gain,
                         sizeof(rule->cwnd_gain)) ||
          brutal_nla_put(&request, BRUTAL_A_LOCKED, &rule->locked,
                         sizeof(rule->locked)) ||
          brutal_nla_put(&request, BRUTAL_A_PERIP, &rule->perip,
                         sizeof(rule->perip)) ||
          (rule->aggregate_set &&
           brutal_nla_put(&request, BRUTAL_A_AGGREGATE_RATE,
                          &rule->aggregate_rate,
                          sizeof(rule->aggregate_rate))) ||
          (rule->max_peers_set &&
           brutal_nla_put(&request, BRUTAL_A_MAX_PEERS, &rule->max_peers,
                          sizeof(rule->max_peers))))))
    {
        close(fd);
        return -1;
    }
    ret = brutal_nl_exchange(fd, &request, NULL, NULL);
    close(fd);
    return ret;
}

int brutal_nl_rule_add(const struct brutal_nl_rule *rule)
{
    return brutal_nl_rule_request(rule, BRUTAL_CMD_RULE_ADD);
}

int brutal_nl_rule_del(const struct brutal_nl_rule *rule)
{
    return brutal_nl_rule_request(rule, BRUTAL_CMD_RULE_DEL);
}

static int brutal_nl_get(uint8_t command, brutal_nl_message_cb callback,
                         void *arg)
{
    struct brutal_nl_request request;
    uint16_t family;
    int fd = brutal_nl_open(&family);
    int ret;

    if (fd < 0)
        return -1;
    brutal_nl_request_init(&request, family, command, 0);
    ret = brutal_nl_exchange(fd, &request, callback, arg);
    close(fd);
    return ret;
}

static int brutal_nl_stats_reply(const struct nlmsghdr *nlh, void *arg)
{
    struct brutal_nl_stats *stats = arg;

    memset(stats, 0, sizeof(*stats));
    if (brutal_nla_copy(nlh, BRUTAL_A_PEER_ALLOC_FAILURES,
                        &stats->peer_alloc_failures,
                        sizeof(stats->peer_alloc_failures), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_PEER_INSERT_FAILURES,
                        &stats->peer_insert_failures,
                        sizeof(stats->peer_insert_failures), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_PEER_FALLBACKS,
                        &stats->peer_fallbacks,
                        sizeof(stats->peer_fallbacks), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_PEER_BUDGET_FALLBACKS,
                        &stats->peer_budget_fallbacks,
                        sizeof(stats->peer_budget_fallbacks), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_PEER_SLOTS, &stats->peer_slots,
                        sizeof(stats->peer_slots), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_PEAK_PEER_SLOTS,
                        &stats->peak_peer_slots,
                        sizeof(stats->peak_peer_slots), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_ACTIVE_PEERS, &stats->active_peers,
                        sizeof(stats->active_peers), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_PEAK_PEERS, &stats->peak_peers,
                        sizeof(stats->peak_peers), 1) ||
        brutal_nla_copy(nlh, BRUTAL_A_MAX_PEERS, &stats->max_peers,
                        sizeof(stats->max_peers), 1))
    {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

int brutal_nl_stats_get(struct brutal_nl_stats *stats)
{
    return brutal_nl_get(BRUTAL_CMD_GET_STATS, brutal_nl_stats_reply, stats);
}

static int brutal_nl_limit_reply(const struct nlmsghdr *nlh, void *arg)
{
    if (brutal_nla_copy(nlh, BRUTAL_A_MAX_PEERS, arg, sizeof(uint32_t), 1))
    {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

int brutal_nl_limit_get(uint32_t *max_peers)
{
    return brutal_nl_get(BRUTAL_CMD_LIMIT_GET, brutal_nl_limit_reply,
                         max_peers);
}

int brutal_nl_limit_set(uint32_t max_peers)
{
    struct brutal_nl_request request;
    uint16_t family;
    int fd = brutal_nl_open(&family);
    int ret;

    if (fd < 0)
        return -1;
    brutal_nl_request_init(&request, family, BRUTAL_CMD_LIMIT_SET, NLM_F_ACK);
    if (brutal_nla_put(&request, BRUTAL_A_MAX_PEERS, &max_peers,
                       sizeof(max_peers)))
    {
        close(fd);
        return -1;
    }
    ret = brutal_nl_exchange(fd, &request, NULL, NULL);
    close(fd);
    return ret;
}
