#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define TCP_BRUTAL_PARAMS 23301

struct brutal_params
{
    uint64_t rate;
    uint32_t cwnd_gain;
    uint64_t group_id;
} __attribute__((packed));

static unsigned long long parse_u64(const char *text)
{
    char *end;
    unsigned long long value;

    errno = 0;
    value = strtoull(text, &end, 10);
    if (errno || !*text || *end)
    {
        fprintf(stderr, "invalid integer: %s\n", text);
        exit(2);
    }
    return value;
}

static void read_back(int fd, const char *phase, uint64_t expected_rate,
                      uint64_t expected_group)
{
    struct brutal_params got = {};
    socklen_t len = sizeof(got);

    if (getsockopt(fd, IPPROTO_TCP, TCP_BRUTAL_PARAMS, &got, &len))
    {
        perror("getsockopt(TCP_BRUTAL_PARAMS)");
        exit(1);
    }
    printf("%s rate=%llu group=%llu gain=%u\n", phase,
           (unsigned long long)got.rate, (unsigned long long)got.group_id,
           got.cwnd_gain);
    fflush(stdout);
    if (got.rate != expected_rate || got.group_id != expected_group)
    {
        fprintf(stderr, "unexpected params: rate=%llu group=%llu\n",
                (unsigned long long)got.rate,
                (unsigned long long)got.group_id);
        exit(1);
    }
}

int main(int argc, char **argv)
{
    const char cc[] = "brutal";
    struct brutal_params params;
    uint64_t group, rate;
    unsigned hold;
    int fd;

    if (argc != 4)
    {
        fprintf(stderr, "usage: %s GROUP_ID RATE_BYTES_PER_SEC HOLD_SECONDS\n",
                argv[0]);
        return 2;
    }
    group = parse_u64(argv[1]);
    rate = parse_u64(argv[2]);
    hold = (unsigned)parse_u64(argv[3]);

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
    {
        perror("socket");
        return 1;
    }
    if (setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, cc, sizeof(cc)))
    {
        perror("setsockopt(TCP_CONGESTION=brutal)");
        return 1;
    }

    params.rate = rate;
    params.cwnd_gain = 20;
    params.group_id = group;
    if (setsockopt(fd, IPPROTO_TCP, TCP_BRUTAL_PARAMS, &params,
                   sizeof(params)))
    {
        perror("setsockopt(TCP_BRUTAL_PARAMS)");
        return 1;
    }

    read_back(fd, "initial", rate, group);
    sleep(hold);
    read_back(fd, "final", rate, group);
    close(fd);
    return 0;
}
