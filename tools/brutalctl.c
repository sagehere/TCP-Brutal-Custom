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
 * Build: cc -O2 -Wall -o brutalctl brutalctl.c
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef RULES_PATH
#define RULES_PATH "/proc/net/tcp_brutal/rules"
#endif
#ifndef PEERS_PATH
#define PEERS_PATH "/proc/net/tcp_brutal/peers"
#endif
#define ROUTE_PROTO "233" /* rtnetlink protocol id marking brutalctl's routes */

static int usage(void)
{
    fputs("usage: brutalctl list\n"
          "       brutalctl peers\n"
          "       brutalctl add <prefix>[/<len>] <rate_mbps> [gain=<tenths>] [nolock] [noroute] [perip]\n"
          "       brutalctl del <prefix>[/<len>]\n"
          "       brutalctl flush\n"
          "\n"
          "All connections to the prefix share the rate as one group. add also installs\n"
          "the route that makes the kernel use brutal for the prefix (ip route replace\n"
          "<prefix> ... congctl lock brutal proto " ROUTE_PROTO "); del and flush remove it.\n"
          "perip gives each peer IP its own shared rate (and requires the default lock).\n"
          "nolock lets applications set their own params on these connections.\n",
          stderr);
    return 2;
}

/* Run argv without a shell; capture stdout into out if given. Returns the exit
 * status, or -1 if the command could not be run. */
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

/* How the prefix is reached today. Returns 0 with dev (and via, if any),
 * 1 for a local address, -1 if there is no route or ip failed. */
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

static int route_add(const char *prefix, int lock)
{
    char via[64], dev[32];
    char *argv[16];
    int n = 0, r = route_lookup(prefix, via, sizeof(via), dev, sizeof(dev));

    if (r)
    {
        fprintf(stderr, "brutalctl: rule added, but no route installed: %s\n",
                r == 1 ? "destination is a local address" : "no route to destination");
        return 1;
    }
    argv[n++] = "ip";
    argv[n++] = ip_family(prefix);
    argv[n++] = "route";
    argv[n++] = "replace";
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
        fprintf(stderr, "brutalctl: rule added, but ip route replace failed\n");
        return 1;
    }
    return 0;
}

static void route_del(const char *prefix)
{
    char *argv[] = {"ip", ip_family(prefix), "route", "del", (char *)prefix, "proto", ROUTE_PROTO, NULL};

    run(argv, NULL, 0, 1); /* may not exist (noroute) */
}

static void route_flush(void)
{
    char *v4[] = {"ip", "-4", "route", "flush", "proto", ROUTE_PROTO, NULL};
    char *v6[] = {"ip", "-6", "route", "flush", "proto", ROUTE_PROTO, NULL};

    run(v4, NULL, 0, 1);
    run(v6, NULL, 0, 1);
}

/* Does the list of brutalctl routes contain dst ("addr/len")? */
static int route_present(const char *dst, char *routes)
{
    char canon[80], *line, *save;
    const char *slash = strchr(dst, '/');

    for (line = strtok_r(routes, "\n", &save); line; line = strtok_r(NULL, "\n", &save))
    {
        size_t n = strcspn(line, " ");

        snprintf(canon, sizeof(canon), "%.*s", (int)n, line);
        if (!strchr(canon, '/') && slash) /* ip prints host routes without /len */
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

/* Copy the value of "key=" from a line of the rules file into out ("" if absent) */
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

static int list_rules(void)
{
    char line[512], dst[64], rate[32], gain[16], lock[8], group[16], id[24], members[16], ips[16], sent[32];
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
    printf("%-30s %11s %5s %5s %7s %6s %4s %8s %5s %10s\n",
           "DESTINATION", "RATE(Mbps)", "GAIN", "LOCK", "GROUP", "ROUTE", "ID", "MEMBERS", "IPS", "SENT(MB)");
    while (fgets(line, sizeof(line), f))
    {
        char copy[sizeof(routes)];

        field(line, "dst", dst, sizeof(dst));
        field(line, "rate", rate, sizeof(rate));
        field(line, "gain", gain, sizeof(gain));
        field(line, "lock", lock, sizeof(lock));
        field(line, "group", group, sizeof(group));
        field(line, "id", id, sizeof(id));
        field(line, "members", members, sizeof(members));
        field(line, "ips", ips, sizeof(ips));
        field(line, "sent", sent, sizeof(sent));
        memcpy(copy, routes, sizeof(copy));
        printf("%-30s %11.2f %5s %5s %7s %6s %4s %8s %5s %10.1f\n",
               dst, strtoull(rate, NULL, 10) * 8 / 1e6, gain,
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

static int list_peers(void)
{
    char line[512], ip[64], family[8];
    unsigned long long rule, rate, gain, members, sent;
    unsigned int rows = 0, line_number = 0;
    FILE *f;
    int fd = open_proc(PEERS_PATH, O_RDONLY);

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
    if (!rows)
        puts("当前无活跃 perip 连接");
    return 0;
}

static int add_rule(int argc, char **argv)
{
    char cmd[256];
    char *end;
    double mbps;
    int n, i, lock = 1, route = 1, ret;

    if (argc < 4)
        return usage();
    mbps = strtod(argv[3], &end);
    if (*end || mbps <= 0)
    {
        fprintf(stderr, "brutalctl: invalid rate '%s' (Mbps)\n", argv[3]);
        return 1;
    }
    n = snprintf(cmd, sizeof(cmd), "add %s rate=%llu", argv[2],
                 (unsigned long long)(mbps * 1e6 / 8 + 0.5));
    for (i = 4; i < argc && n < (int)sizeof(cmd) - 16; i++)
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
            if (!lock)
                return usage();
        }
        else if (!strcmp(argv[i], "lock"))
            lock = 1;
        else if (strncmp(argv[i], "gain=", 5))
            return usage();
        n += snprintf(cmd + n, sizeof(cmd) - n, " %s", argv[i]);
    }
    if (i < argc)
        return usage();
    if (!lock && strstr(cmd, " perip"))
        return usage();
    strcat(cmd, "\n");
    ret = send_cmd(cmd);
    if (ret)
        return ret;
    if (route)
        return route_add(argv[2], lock);
    route_del(argv[2]); /* the rule was updated to noroute */
    return 0;
}

int main(int argc, char **argv)
{
    char cmd[256];
    int ret;

    if (argc < 2)
        return usage();
    if (!strcmp(argv[1], "list") || !strcmp(argv[1], "ls"))
        return argc == 2 ? list_rules() : usage();
    if (!strcmp(argv[1], "peers"))
        return argc == 2 ? list_peers() : usage();
    if (!strcmp(argv[1], "add"))
        return add_rule(argc, argv);
    if (!strcmp(argv[1], "del") && argc == 3)
    {
        snprintf(cmd, sizeof(cmd), "del %s\n", argv[2]);
        ret = send_cmd(cmd);
        if (!ret)
            route_del(argv[2]);
        return ret;
    }
    if (!strcmp(argv[1], "flush") && argc == 2)
    {
        ret = send_cmd("flush\n");
        if (!ret)
            route_flush();
        return ret;
    }
    return usage();
}
