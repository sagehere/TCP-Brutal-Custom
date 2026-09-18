/*
 * brutalctl - manage TCP Brutal destination rules.
 *
 * A rule, kept by the kernel module in /proc/net/tcp_brutal/rules, puts every
 * connection to a destination prefix into one group sharing a rate, without
 * application support. For the kernel to actually use brutal for those
 * connections a route to the prefix must select it, so unless "noroute" is
 * given, add installs one with the ip command (same next hop as today, plus
 * "congctl lock brutal") and del/flush remove it. Routes created here carry
 * protocol 233 and never touch routes created by anything else. "peers" shows
 * the active per-IP groups exported by /proc/net/tcp_brutal/peers.
 *
 * Build: cc -O2 -Wall -o brutalctl brutalctl.c brutal_netlink.c
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include "../brutal_uapi.h"
#include "brutal_netlink.h"

#ifndef RULES_PATH
#define RULES_PATH "/proc/net/tcp_brutal/rules"
#endif
#ifndef PEERS_PATH
#define PEERS_PATH "/proc/net/tcp_brutal/peers"
#endif
#ifndef STATS_PATH
#define STATS_PATH "/proc/net/tcp_brutal/stats"
#endif
#ifndef PORT_STATS_PATH
#define PORT_STATS_PATH "/proc/net/tcp_brutal/port_stats"
#endif
#ifndef LIMITS_PATH
#define LIMITS_PATH "/proc/net/tcp_brutal/limits"
#endif
#define ROUTE_PROTO "233" /* rtnetlink protocol id marking brutalctl's routes */

static int usage(void)
{
    fputs("usage: brutalctl info\n"
          "       brutalctl stats\n"
          "       brutalctl port-stats [ports]\n"
          "       brutalctl limits [max_peers]\n"
          "       brutalctl list\n"
          "       brutalctl peers [--rule ID] [--ip ADDRESS] [--family 4|6] [--limit N]\n"
          "       brutalctl add <prefix>[/<len>] <rate_mbps> [gain=<tenths>] [nolock] [noroute] [perip] [aggregate=Mbps] [maxpeers=N]\n"
          "       brutalctl del <prefix>[/<len>]\n"
          "       brutalctl flush\n"
          "\n"
          "All connections to the prefix share the rate as one group. add also installs\n"
          "a dedicated proto " ROUTE_PROTO " route when no foreign exact route exists;\n"
          "del and flush remove only routes owned by brutalctl.\n"
          "perip gives each peer IP its own shared rate (and requires the default lock).\n"
          "aggregate=Mbps optionally caps all children of a perip rule; 0 disables it.\n"
          "maxpeers=N bounds per-IP peer groups for that rule; 0 means unlimited.\n"
          "nolock lets applications set their own params on these connections.\n",
          stderr);
    return 2;
}

static int run(char *const argv[], char *out, size_t size, int quiet)
{
    int fds[2], status;
    size_t n = 0;
    ssize_t r;
    char sink[256];
    pid_t pid;

    if (pipe(fds))
        return -1;
    pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0)
    {
        int null = open("/dev/null", O_WRONLY);

        dup2(fds[1], 1);
        if (quiet && null >= 0)
            dup2(null, 2);
        close(fds[0]);
        close(fds[1]);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(fds[1]);
    while (out && n + 1 < size && (r = read(fds[0], out + n, size - 1 - n)) > 0)
        n += r;
    if (out)
        out[n] = 0;
    while (read(fds[0], sink, sizeof(sink)) > 0)
        ;
    close(fds[0]);
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static char *ip_family(const char *prefix)
{
    return strchr(prefix, ':') ? "-6" : "-4";
}

static int route_lookup(const char *prefix, char *via, size_t vsize, char *dev, size_t dsize)
{
    char addr[64], out[512], *tok, *save, *slash;
    char *argv[] = {"ip", ip_family(prefix), "route", "get", addr, NULL};

    snprintf(addr, sizeof(addr), "%s", prefix);
    if ((slash = strchr(addr, '/')))
        *slash = 0;
    via[0] = dev[0] = 0;
    if (run(argv, out, sizeof(out), 1) != 0)
        return -1;
    if (!strncmp(out, "local ", 6))
        return 1;
    for (tok = strtok_r(out, " \n", &save); tok; tok = strtok_r(NULL, " \n", &save))
    {
        if (!strcmp(tok, "via") && (tok = strtok_r(NULL, " \n", &save)))
            snprintf(via, vsize, "%s", tok);
        else if (!strcmp(tok, "dev") && (tok = strtok_r(NULL, " \n", &save)))
            snprintf(dev, dsize, "%s", tok);
    }
    return dev[0] ? 0 : -1;
}

enum route_owner
{
    ROUTE_NONE = 0,
    ROUTE_OURS,
    ROUTE_FOREIGN,
    ROUTE_CHECK_ERROR,
};

static int route_line_is_ours(char *line)
{
    char *tok, *save;

    for (tok = strtok_r(line, " \t", &save); tok; tok = strtok_r(NULL, " \t", &save))
    {
        if (!strcmp(tok, "proto"))
        {
            tok = strtok_r(NULL, " \t", &save);
            return tok && !strcmp(tok, ROUTE_PROTO);
        }
    }
    return 0;
}

static enum route_owner route_owner(const char *prefix)
{
    char out[16384], copy[16384], *line, *save;
    char *argv[] = {"ip", "-N", ip_family(prefix), "route", "show", "exact", (char *)prefix, NULL};
    int saw_route = 0;

    if (run(argv, out, sizeof(out), 1) != 0)
    {
        fprintf(stderr, "brutalctl: cannot inspect existing route for %s\n", prefix);
        return ROUTE_CHECK_ERROR;
    }
    if (strlen(out) == sizeof(out) - 1)
    {
        fprintf(stderr, "brutalctl: route inspection output is too large for %s\n", prefix);
        return ROUTE_CHECK_ERROR;
    }
    if (!out[0])
        return ROUTE_NONE;
    snprintf(copy, sizeof(copy), "%s", out);
    for (line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save))
    {
        char route[16384];

        if (!*line)
            continue;
        saw_route = 1;
        snprintf(route, sizeof(route), "%s", line);
        if (!route_line_is_ours(route))
        {
            fprintf(stderr,
                    "brutalctl: refusing to replace existing route for %s; "
                    "use noroute or remove the conflicting route explicitly\n",
                    prefix);
            return ROUTE_FOREIGN;
        }
    }
    return saw_route ? ROUTE_OURS : ROUTE_NONE;
}

static int route_add(const char *prefix, int lock)
{
    char via[64], dev[32];
    char *argv[16];
    enum route_owner owner = route_owner(prefix);
    int n = 0, r;

    if (owner == ROUTE_FOREIGN || owner == ROUTE_CHECK_ERROR)
        return 1;
    r = route_lookup(prefix, via, sizeof(via), dev, sizeof(dev));
    if (r)
    {
        fprintf(stderr, "brutalctl: rule added, but no route installed: %s\n",
                r == 1 ? "destination is a local address" : "no route to destination");
        return 1;
    }
    argv[n++] = "ip";
    argv[n++] = ip_family(prefix);
    argv[n++] = "route";
    argv[n++] = owner == ROUTE_OURS ? "replace" : "add";
    argv[n++] = (char *)prefix;
    if (via[0])
    {
        argv[n++] = "via";
        argv[n++] = via;
    }
    argv[n++] = "dev";
    argv[n++] = dev;
    argv[n++] = "congctl";
    if (lock)
        argv[n++] = "lock";
    argv[n++] = "brutal";
    argv[n++] = "proto";
    argv[n++] = ROUTE_PROTO;
    argv[n] = NULL;
    if (run(argv, NULL, 0, 0) != 0)
    {
        fprintf(stderr, "brutalctl: rule added, but ip route %s failed\n",
                owner == ROUTE_OURS ? "replace" : "add");
        return 1;
    }
    return 0;
}

static void route_del(const char *prefix)
{
    char *argv[] = {"ip", ip_family(prefix), "route", "del", (char *)prefix, "proto", ROUTE_PROTO, NULL};

    run(argv, NULL, 0, 1);
}

static void route_flush(void)
{
    char *v4[] = {"ip", "-4", "route", "flush", "proto", ROUTE_PROTO, NULL};
    char *v6[] = {"ip", "-6", "route", "flush", "proto", ROUTE_PROTO, NULL};

    run(v4, NULL, 0, 1);
    run(v6, NULL, 0, 1);
}

static int route_present(const char *dst, char *routes)
{
    char canon[80], *line, *save;
    const char *slash = strchr(dst, '/');

    for (line = strtok_r(routes, "\n", &save); line; line = strtok_r(NULL, "\n", &save))
    {
        size_t n = strcspn(line, " ");

        snprintf(canon, sizeof(canon), "%.*s", (int)n, line);
        if (!strchr(canon, '/') && slash)
            snprintf(canon + n, sizeof(canon) - n, "/%d", strchr(canon, ':') ? 128 : 32);
        if (!strcmp(canon, dst))
            return 1;
    }
    return 0;
}

static int open_proc(const char *path, int flags)
{
    int fd = open(path, flags);

    if (fd < 0)
    {
        if (errno == ENOENT)
        {
            if (!strcmp(path, PEERS_PATH) && access(RULES_PATH, F_OK) == 0)
                fprintf(stderr,
                        "brutalctl: loaded module is too old for the peers view; "
                        "update TCP Brutal Custom or reboot to finish a staged update\n");
            else
                fprintf(stderr, "brutalctl: TCP Brutal Custom is not loaded\n");
        }
        else if (errno == EACCES)
            fprintf(stderr, "brutalctl: permission denied reading %s\n", path);
        else
            fprintf(stderr, "brutalctl: %s: %s\n", path, strerror(errno));
    }
    return fd;
}

static int open_rules(int flags)
{
    return open_proc(RULES_PATH, flags);
}

static int appendf(char *buf, size_t size, size_t *used, const char *fmt, ...)
{
    va_list ap;
    int n;

    if (*used >= size)
        return -1;
    va_start(ap, fmt);
    n = vsnprintf(buf + *used, size - *used, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= size - *used)
        return -1;
    *used += (size_t)n;
    return 0;
}

static int send_cmd(const char *cmd)
{
    int fd = open_rules(O_WRONLY);
    const char *msg;

    if (fd < 0)
        return 1;
    if (write(fd, cmd, strlen(cmd)) >= 0)
    {
        close(fd);
        return 0;
    }
    switch (errno)
    {
    case EINVAL:
        msg = "invalid prefix or parameters";
        break;
    case ENOENT:
        msg = "no such rule";
        break;
    default:
        msg = strerror(errno);
    }
    close(fd);
    fprintf(stderr, "brutalctl: %s\n", msg);
    return 1;
}

static char *field(const char *line, const char *key, char *out, size_t size)
{
    size_t klen = strlen(key);
    const char *p = line;

    out[0] = 0;
    while ((p = strstr(p, key)))
    {
        if ((p == line || p[-1] == ' ') && p[klen] == '=')
        {
            size_t n = strcspn(p + klen + 1, " \n");

            if (n >= size)
                n = size - 1;
            memcpy(out, p + klen + 1, n);
            out[n] = 0;
            break;
        }
        p += klen;
    }
    return out;
}

static int print_proc(const char *path)
{
    char buffer[4096];
    ssize_t length;
    int fd = open_proc(path, O_RDONLY);

    if (fd < 0)
        return 1;
    while ((length = read(fd, buffer, sizeof(buffer))) > 0)
        if (fwrite(buffer, 1, length, stdout) != (size_t)length)
        {
            close(fd);
            return 1;
        }
    close(fd);
    return length < 0;
}

static int parse_nl_prefix(const char *text, struct brutal_nl_rule *rule)
{
    char copy[80], *slash;
    long plen;

    if (strlen(text) >= sizeof(copy))
        return -1;
    strcpy(copy, text);
    slash = strchr(copy, '/');
    if (slash)
    {
        char *end;

        *slash++ = 0;
        errno = 0;
        plen = strtol(slash, &end, 10);
        if (errno || *end || plen < 0)
            return -1;
    }
    else
        plen = -1;
    memset(rule, 0, sizeof(*rule));
    if (inet_pton(AF_INET, copy, &rule->address.v4) == 1)
    {
        rule->family = AF_INET;
        rule->plen = plen < 0 ? 32 : (uint8_t)plen;
        return plen <= 32 ? 0 : -1;
    }
    if (inet_pton(AF_INET6, copy, &rule->address.v6) == 1)
    {
        rule->family = AF_INET6;
        rule->plen = plen < 0 ? 128 : (uint8_t)plen;
        return plen <= 128 ? 0 : -1;
    }
    return -1;
}

struct list_rules_nl_ctx
{
    const char *routes;
};

static int list_rule_nl(const struct brutal_nl_rule *rule, void *arg)
{
    const struct list_rules_nl_ctx *ctx = arg;
    char address[INET6_ADDRSTRLEN], dst[80], copy[12288];

    if (!inet_ntop(rule->family,
                   rule->family == AF_INET ? (const void *)&rule->address.v4
                                           : (const void *)&rule->address.v6,
                   address, sizeof(address)))
        return -1;
    snprintf(dst, sizeof(dst), "%s/%u", address, rule->plen);
    snprintf(copy, sizeof(copy), "%s", ctx->routes);
    printf("%-30s %11.2f %11.2f %5u %5s %7s %6s %4llu %8u %5u %10.1f\n",
           dst, rule->rate * 8 / 1e6, rule->aggregate_rate * 8 / 1e6,
           rule->cwnd_gain, rule->locked ? "yes" : "no",
           rule->perip ? "perip" : "shared",
           route_present(dst, copy) ? "yes" : "no",
           (unsigned long long)rule->id, rule->members, rule->active_peers,
           rule->sent_bytes / 1e6);
    return 0;
}

static int list_rules_netlink(const char *routes)
{
    struct list_rules_nl_ctx ctx = {.routes = routes};

    printf("%-30s %11s %11s %5s %5s %7s %6s %4s %8s %5s %10s\n",
           "DESTINATION", "RATE(Mbps)", "AGGR(Mbps)", "GAIN", "LOCK",
           "GROUP", "ROUTE", "ID", "MEMBERS", "IPS", "SENT(MB)");
    if (brutal_nl_rule_dump(list_rule_nl, &ctx))
    {
        perror("brutalctl: Generic Netlink rule dump");
        return 1;
    }
    return 0;
}

static int list_rules(void)
{
    char line[512], dst[64], rate[32], aggregate[32], gain[16], lock[8], group[16], id[24], members[16], ips[16], sent[32];
    char routes[8192], routes6[4096];
    char *v4[] = {"ip", "-4", "route", "show", "proto", ROUTE_PROTO, NULL};
    char *v6[] = {"ip", "-6", "route", "show", "proto", ROUTE_PROTO, NULL};
    FILE *f;
    int fd = open_rules(O_RDONLY);

    if (fd < 0)
        return 1;
    f = fdopen(fd, "r");
    run(v4, routes, sizeof(routes) - sizeof(routes6), 1);
    run(v6, routes6, sizeof(routes6), 1);
    strcat(routes, routes6);
    if (brutal_nl_available())
    {
        fclose(f);
        return list_rules_netlink(routes);
    }
    printf("%-30s %11s %11s %5s %5s %7s %6s %4s %8s %5s %10s\n",
           "DESTINATION", "RATE(Mbps)", "AGGR(Mbps)", "GAIN", "LOCK",
           "GROUP", "ROUTE", "ID", "MEMBERS", "IPS", "SENT(MB)");
    while (fgets(line, sizeof(line), f))
    {
        char copy[sizeof(routes)];

        field(line, "dst", dst, sizeof(dst));
        field(line, "rate", rate, sizeof(rate));
        field(line, "aggregate", aggregate, sizeof(aggregate));
        field(line, "gain", gain, sizeof(gain));
        field(line, "lock", lock, sizeof(lock));
        field(line, "group", group, sizeof(group));
        field(line, "id", id, sizeof(id));
        field(line, "members", members, sizeof(members));
        field(line, "ips", ips, sizeof(ips));
        field(line, "sent", sent, sizeof(sent));
        memcpy(copy, routes, sizeof(copy));
        printf("%-30s %11.2f %11.2f %5s %5s %7s %6s %4s %8s %5s %10.1f\n",
               dst, strtoull(rate, NULL, 10) * 8 / 1e6,
               strtoull(aggregate, NULL, 10) * 8 / 1e6, gain,
               strcmp(lock, "1") ? "no" : "yes", group[0] ? group : "shared",
               route_present(dst, copy) ? "yes" : "no", id, members,
               ips[0] ? ips : "0", strtoull(sent, NULL, 10) / 1e6);
    }
    fclose(f);
    return 0;
}

static int parse_u64(const char *line, const char *key, unsigned long long *value)
{
    char text[32], *end;

    field(line, key, text, sizeof(text));
    if (text[0] < '0' || text[0] > '9')
        return -1;
    errno = 0;
    *value = strtoull(text, &end, 10);
    return errno || *end ? -1 : 0;
}

struct list_peers_nl_ctx
{
    const char *ip_filter;
    const char *family_filter;
    unsigned long long rule_filter;
    unsigned int rows;
    unsigned int limit;
    int truncated;
};

static int list_peer_nl(const struct brutal_nl_peer *peer, void *arg)
{
    struct list_peers_nl_ctx *ctx = arg;
    char ip[INET6_ADDRSTRLEN];
    const char *family = peer->family == AF_INET ? "4" : "6";

    if (!inet_ntop(peer->family,
                   peer->family == AF_INET ? (const void *)&peer->address.v4
                                           : (const void *)&peer->address.v6,
                   ip, sizeof(ip)))
        return -1;
    if ((ctx->ip_filter && strcmp(ctx->ip_filter, ip)) ||
        (ctx->family_filter && strcmp(ctx->family_filter, family)) ||
        (ctx->rule_filter && ctx->rule_filter != peer->rule_id))
        return 0;
    if (ctx->limit && ctx->rows == ctx->limit)
    {
        ctx->truncated = 1;
        return 0;
    }
    printf("%-39s %6s %8llu %11.2f %5u %11u %10.1f\n",
           ip, peer->family == AF_INET ? "IPv4" : "IPv6",
           (unsigned long long)peer->rule_id, peer->rate * 8 / 1e6,
           peer->cwnd_gain, peer->members, peer->sent_bytes / 1e6);
    ctx->rows++;
    return 0;
}

static int list_peers_netlink(const char *ip_filter, const char *family_filter,
                              unsigned long long rule_filter,
                              unsigned int limit)
{
    struct list_peers_nl_ctx ctx = {
        .ip_filter = ip_filter,
        .family_filter = family_filter,
        .rule_filter = rule_filter,
        .limit = limit,
    };

    printf("%-39s %6s %8s %11s %5s %11s %10s\n",
           "PEER IP", "FAMILY", "RULE ID", "RATE(Mbps)", "GAIN",
           "CONNECTIONS", "SENT(MB)");
    if (brutal_nl_peer_dump(list_peer_nl, &ctx))
    {
        perror("brutalctl: Generic Netlink peer dump");
        return 1;
    }
    if (ctx.truncated)
        fprintf(stderr, "brutalctl: output limited to %u peers\n", limit);
    if (!ctx.rows)
        puts("当前无活跃 perip 连接");
    return 0;
}

static int list_peers(int argc, char **argv)
{
    char line[512], ip[64], family[8];
    unsigned long long rule, rate, gain, members, sent;
    unsigned long long rule_filter = 0;
    unsigned int rows = 0, line_number = 0, limit = 0;
    int truncated = 0;
    const char *ip_filter = NULL, *family_filter = NULL;
    FILE *f;
    int fd, i;

    for (i = 2; i < argc; i += 2)
    {
        char *end;
        unsigned long long value;

        if (i + 1 == argc)
            return usage();
        if (!strcmp(argv[i], "--ip"))
            ip_filter = argv[i + 1];
        else if (!strcmp(argv[i], "--family") &&
                 (!strcmp(argv[i + 1], "4") || !strcmp(argv[i + 1], "6")))
            family_filter = argv[i + 1];
        else if (!strcmp(argv[i], "--rule") || !strcmp(argv[i], "--limit"))
        {
            errno = 0;
            value = strtoull(argv[i + 1], &end, 10);
            if (errno || *end || (!strcmp(argv[i], "--limit") && value > UINT_MAX))
                return usage();
            if (!strcmp(argv[i], "--rule"))
                rule_filter = value;
            else
                limit = (unsigned int)value;
        }
        else
            return usage();
    }

    if (brutal_nl_available())
        return list_peers_netlink(ip_filter, family_filter, rule_filter, limit);

    fd = open_proc(PEERS_PATH, O_RDONLY);
    if (fd < 0)
        return 1;
    f = fdopen(fd, "r");
    if (!f)
    {
        int error = errno;
        close(fd);
        fprintf(stderr, "brutalctl: cannot read %s: %s\n", PEERS_PATH, strerror(error));
        return 1;
    }
    printf("%-39s %6s %8s %11s %5s %11s %10s\n",
           "PEER IP", "FAMILY", "RULE ID", "RATE(Mbps)", "GAIN", "CONNECTIONS", "SENT(MB)");
    while (fgets(line, sizeof(line), f))
    {
        line_number++;
        field(line, "ip", ip, sizeof(ip));
        field(line, "family", family, sizeof(family));
        if (!ip[0] || (strcmp(family, "4") && strcmp(family, "6")) ||
            parse_u64(line, "rule", &rule) || parse_u64(line, "rate", &rate) ||
            parse_u64(line, "gain", &gain) || parse_u64(line, "members", &members) ||
            parse_u64(line, "sent", &sent))
        {
            fclose(f);
            fprintf(stderr, "brutalctl: invalid peers data on line %u\n", line_number);
            return 1;
        }
        if ((ip_filter && strcmp(ip_filter, ip)) ||
            (family_filter && strcmp(family_filter, family)) ||
            (rule_filter && rule_filter != rule))
            continue;
        if (limit && rows == limit)
        {
            truncated = 1;
            break;
        }
        printf("%-39s %6s %8llu %11.2f %5llu %11llu %10.1f\n",
               ip, !strcmp(family, "4") ? "IPv4" : "IPv6", rule,
               rate * 8 / 1e6, gain, members, sent / 1e6);
        rows++;
    }
    if (ferror(f))
    {
        fclose(f);
        fprintf(stderr, "brutalctl: failed while reading %s\n", PEERS_PATH);
        return 1;
    }
    fclose(f);
    if (truncated)
        fprintf(stderr, "brutalctl: output limited to %u peers\n", limit);
    if (!rows)
        puts("当前无活跃 perip 连接");
    return 0;
}

static int show_info(void)
{
    static const struct
    {
        unsigned long long bit;
        const char *name;
    } caps[] = {
        {BRUTAL_CAP_PERIP, "perip"},
        {BRUTAL_CAP_NETNS, "netns"},
        {BRUTAL_CAP_EXACT_RULE_HASH, "exact-rule-hash"},
        {BRUTAL_CAP_PEER_STATS, "peer-stats"},
        {BRUTAL_CAP_TC_AGGREGATE_MANAGER, "tc-aggregate-manager"},
        {BRUTAL_CAP_PEER_BUDGET, "peer-budget"},
        {BRUTAL_CAP_PREFIX_INDEX, "prefix-index"},
        {BRUTAL_CAP_KERNEL_AGGREGATE, "kernel-aggregate"},
        {BRUTAL_CAP_GENL, "genl"},
        {BRUTAL_CAP_PORT_STATS, "port-stats"},
    };
    struct brutal_info_v1 info;
    int i, first = 1;

    if (brutal_nl_info_get(&info))
    {
        perror("brutalctl: Generic Netlink GET_INFO");
        return 1;
    }
    if (info.size != sizeof(info) || info.abi_version != BRUTAL_INFO_ABI_V1)
    {
        fprintf(stderr, "brutalctl: unsupported TCP_BRUTAL_INFO response\n");
        return 1;
    }

    printf("version=%u.%u.%u\n", (info.version >> 16) & 0xff,
           (info.version >> 8) & 0xff, info.version & 0xff);
    printf("vendor=%s\n", info.vendor_id == BRUTAL_VENDOR_CUSTOM
                              ? "tcp-brutal-custom"
                              : "unknown");
    printf("abi=%u\n", info.abi_version);
    printf("build=%.*s\n", BRUTAL_BUILD_ID_LEN, (char *)info.build_id);
    printf("capabilities=0x%016llx\n", (unsigned long long)info.capabilities);
    fputs("capability_names=", stdout);
    for (i = 0; i < (int)(sizeof(caps) / sizeof(caps[0])); i++)
    {
        if (!(info.capabilities & caps[i].bit))
            continue;
        printf("%s%s", first ? "" : ",", caps[i].name);
        first = 0;
    }
    putchar('\n');
    return 0;
}

static int show_stats(void)
{
    struct brutal_nl_stats stats;

    if (!brutal_nl_available())
        return print_proc(STATS_PATH);
    if (brutal_nl_stats_get(&stats))
    {
        perror("brutalctl: Generic Netlink stats");
        return 1;
    }
    printf("peer_alloc_failures=%llu\n"
           "peer_insert_failures=%llu\n"
           "peer_fallback_connections=%llu\n"
           "peer_budget_fallbacks=%llu\n"
           "peer_slots=%u\n"
           "peak_peer_slots=%u\n"
           "max_peers=%u\n"
           "active_peer_groups=%u\n"
           "peak_peer_groups=%u\n",
           (unsigned long long)stats.peer_alloc_failures,
           (unsigned long long)stats.peer_insert_failures,
           (unsigned long long)stats.peer_fallbacks,
           (unsigned long long)stats.peer_budget_fallbacks,
           stats.peer_slots, stats.peak_peer_slots, stats.max_peers,
           stats.active_peers, stats.peak_peers);
    return 0;
}

static int show_port_stats(int argc, char **argv)
{
    int fd, length;
    char command[4096];

    if (argc == 2)
        return print_proc(PORT_STATS_PATH);
    if (argc != 3 || strlen(argv[2]) > 4000)
        return usage();
    fd = open_proc(PORT_STATS_PATH, O_WRONLY);
    if (fd < 0)
        return 1;
    length = snprintf(command, sizeof(command), "ports=%s\n", argv[2]);
    if (write(fd, command, length) != length)
    {
        close(fd);
        perror("brutalctl: port-stats");
        return 1;
    }
    close(fd);
    return print_proc(PORT_STATS_PATH);
}

static int show_limits(int argc, char **argv)
{
    uint32_t max_peers;

    if (argc == 3)
    {
        char *end;
        unsigned long long value;

        errno = 0;
        value = strtoull(argv[2], &end, 10);
        if (errno || *end || value > INT_MAX)
            return usage();
        max_peers = value;
        if (brutal_nl_available())
        {
            if (brutal_nl_limit_set(max_peers))
            {
                perror("brutalctl: Generic Netlink limit set");
                return 1;
            }
        }
        else
        {
            char command[64];
            int fd = open_proc(LIMITS_PATH, O_WRONLY);
            int length;

            if (fd < 0)
                return 1;
            length = snprintf(command, sizeof(command), "max_peers=%u\n",
                              max_peers);
            if (write(fd, command, length) != length)
            {
                close(fd);
                perror("brutalctl: limits");
                return 1;
            }
            close(fd);
        }
    }
    if (brutal_nl_available())
    {
        if (brutal_nl_limit_get(&max_peers))
        {
            perror("brutalctl: Generic Netlink limit get");
            return 1;
        }
        printf("max_peers=%u\noverflow=hashed_fallback\n", max_peers);
        return 0;
    }
    return print_proc(LIMITS_PATH);
}

static int parse_nl_add_command(const char *command, struct brutal_nl_rule *rule)
{
    char copy[256], *save, *token;

    if (strlen(command) >= sizeof(copy))
        return -1;
    strcpy(copy, command);
    token = strtok_r(copy, " \n", &save);
    if (!token || strcmp(token, "add"))
        return -1;
    token = strtok_r(NULL, " \n", &save);
    if (!token || parse_nl_prefix(token, rule))
        return -1;
    rule->cwnd_gain = 20;
    rule->locked = 1;
    while ((token = strtok_r(NULL, " \n", &save)))
    {
        if (!strncmp(token, "rate=", 5))
            rule->rate = strtoull(token + 5, NULL, 10);
        else if (!strncmp(token, "gain=", 5))
            rule->cwnd_gain = strtoul(token + 5, NULL, 10);
        else if (!strncmp(token, "aggregate=", 10))
        {
            rule->aggregate_rate = strtoull(token + 10, NULL, 10);
            rule->aggregate_set = 1;
        }
        else if (!strncmp(token, "maxpeers=", 9))
        {
            rule->max_peers = strtoul(token + 9, NULL, 10);
            rule->max_peers_set = 1;
        }
        else if (!strcmp(token, "perip"))
            rule->perip = 1;
        else if (!strcmp(token, "nolock"))
            rule->locked = 0;
        else if (!strcmp(token, "lock"))
            rule->locked = 1;
    }
    return rule->rate ? 0 : -1;
}

static int add_rule(int argc, char **argv)
{
    char cmd[256];
    char *end;
    double mbps;
    size_t used = 0;
    int i, lock = 1, route = 1, perip = 0, aggregate_set = 0;
    int maxpeers_set = 0, ret;

    if (argc < 4)
        return usage();
    if (strlen(argv[2]) >= 80)
    {
        fprintf(stderr, "brutalctl: prefix is too long\n");
        return 1;
    }
    errno = 0;
    mbps = strtod(argv[3], &end);
    if (errno || *end || !isfinite(mbps) || mbps <= 0 || mbps > 1000000.0)
    {
        fprintf(stderr, "brutalctl: invalid rate '%s' (Mbps)\n", argv[3]);
        return 1;
    }
    if (appendf(cmd, sizeof(cmd), &used, "add %s rate=%llu", argv[2],
                (unsigned long long)(mbps * 1e6 / 8 + 0.5)))
    {
        fprintf(stderr, "brutalctl: command is too long\n");
        return 1;
    }
    for (i = 4; i < argc; i++)
    {
        if (!strcmp(argv[i], "noroute"))
        {
            route = 0;
            continue;
        }
        if (!strcmp(argv[i], "nolock"))
            lock = 0;
        else if (!strcmp(argv[i], "perip"))
        {
            perip = 1;
            if (!lock)
                return usage();
        }
        else if (!strcmp(argv[i], "lock"))
            lock = 1;
        else if (!strncmp(argv[i], "maxpeers=", 9))
        {
            char *limit_end;
            unsigned long long limit;

            if (maxpeers_set)
                return usage();
            errno = 0;
            limit = strtoull(argv[i] + 9, &limit_end, 10);
            if (errno || *limit_end || limit > INT_MAX)
            {
                fprintf(stderr, "brutalctl: invalid maxpeers '%s'\n", argv[i] + 9);
                return 1;
            }
            maxpeers_set = 1;
        }
        else if (!strncmp(argv[i], "aggregate=", 10))
        {
            double aggregate;

            if (aggregate_set)
                return usage();
            errno = 0;
            aggregate = strtod(argv[i] + 10, &end);
            if (errno || *end || !isfinite(aggregate) || aggregate < 0 ||
                aggregate > 1000000.0)
            {
                fprintf(stderr, "brutalctl: invalid aggregate rate '%s' (Mbps)\n",
                        argv[i] + 10);
                return 1;
            }
            if (appendf(cmd, sizeof(cmd), &used, " aggregate=%llu",
                        (unsigned long long)(aggregate * 1e6 / 8 + 0.5)))
            {
                fprintf(stderr, "brutalctl: command is too long\n");
                return 1;
            }
            aggregate_set = 1;
            continue;
        }
        else if (strncmp(argv[i], "gain=", 5))
            return usage();
        if (appendf(cmd, sizeof(cmd), &used, " %s", argv[i]))
        {
            fprintf(stderr, "brutalctl: command is too long\n");
            return 1;
        }
    }
    if (!lock && perip)
        return usage();
    if (maxpeers_set && !perip)
    {
        fprintf(stderr, "brutalctl: maxpeers requires perip\n");
        return 1;
    }
    if (aggregate_set && !perip)
    {
        fprintf(stderr, "brutalctl: aggregate requires perip\n");
        return 1;
    }
    if (route)
    {
        enum route_owner owner = route_owner(argv[2]);
        if (owner == ROUTE_FOREIGN || owner == ROUTE_CHECK_ERROR)
            return 1;
    }
    if (appendf(cmd, sizeof(cmd), &used, "\n"))
    {
        fprintf(stderr, "brutalctl: command is too long\n");
        return 1;
    }
    if (brutal_nl_available())
    {
        struct brutal_nl_rule rule;

        if (parse_nl_add_command(cmd, &rule))
        {
            fprintf(stderr, "brutalctl: cannot encode Generic Netlink rule\n");
            return 1;
        }
        ret = brutal_nl_rule_add(&rule);
        if (ret)
        {
            perror("brutalctl: Generic Netlink rule add");
            ret = 1;
        }
    }
    else
        ret = send_cmd(cmd);
    if (ret)
        return ret;
    if (route)
        return route_add(argv[2], lock);
    route_del(argv[2]);
    return 0;
}

static int delete_rule_nl(const struct brutal_nl_rule *rule, void *arg)
{
    (void)arg;
    return brutal_nl_rule_del(rule);
}

int main(int argc, char **argv)
{
    char cmd[256];
    int ret;

    if (argc < 2)
        return usage();
    if (!strcmp(argv[1], "info"))
        return argc == 2 ? show_info() : usage();
    if (!strcmp(argv[1], "stats"))
        return argc == 2 ? show_stats() : usage();
    if (!strcmp(argv[1], "port-stats"))
        return argc == 2 || argc == 3 ? show_port_stats(argc, argv) : usage();
    if (!strcmp(argv[1], "limits"))
        return argc == 2 || argc == 3 ? show_limits(argc, argv) : usage();
    if (!strcmp(argv[1], "list") || !strcmp(argv[1], "ls"))
        return argc == 2 ? list_rules() : usage();
    if (!strcmp(argv[1], "peers"))
        return list_peers(argc, argv);
    if (!strcmp(argv[1], "add"))
        return add_rule(argc, argv);
    if (!strcmp(argv[1], "del") && argc == 3)
    {
        int n;

        if (brutal_nl_available())
        {
            struct brutal_nl_rule rule;

            if (parse_nl_prefix(argv[2], &rule))
                return usage();
            ret = brutal_nl_rule_del(&rule);
            if (ret)
            {
                perror("brutalctl: Generic Netlink rule delete");
                ret = 1;
            }
            if (!ret)
                route_del(argv[2]);
            return ret != 0;
        }
        n = snprintf(cmd, sizeof(cmd), "del %s\n", argv[2]);
        if (n < 0 || (size_t)n >= sizeof(cmd))
        {
            fprintf(stderr, "brutalctl: prefix is too long\n");
            return 1;
        }
        ret = send_cmd(cmd);
        if (!ret)
            route_del(argv[2]);
        return ret;
    }
    if (!strcmp(argv[1], "flush") && argc == 2)
    {
        if (brutal_nl_available())
        {
            ret = brutal_nl_rule_dump(delete_rule_nl, NULL);
            if (ret)
            {
                perror("brutalctl: Generic Netlink rule flush");
                ret = 1;
            }
        }
        else
            ret = send_cmd("flush\n");
        if (!ret)
            route_flush();
        return ret;
    }
    return usage();
}
