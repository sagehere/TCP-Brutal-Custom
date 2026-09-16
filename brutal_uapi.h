#ifndef BRUTAL_UAPI_H
#define BRUTAL_UAPI_H

#include <linux/types.h>

#define TCP_BRUTAL_PARAMS 23301
#define TCP_BRUTAL_VERSION 23302
#define TCP_BRUTAL_INFO 23303

#define BRUTAL_INFO_ABI_V1 1
#define BRUTAL_VENDOR_UPSTREAM 0
#define BRUTAL_VENDOR_CUSTOM 1
#define BRUTAL_BUILD_ID_LEN 40

#define BRUTAL_CAP_PERIP (1ULL << 0)
#define BRUTAL_CAP_NETNS (1ULL << 1)
#define BRUTAL_CAP_EXACT_RULE_HASH (1ULL << 2)
#define BRUTAL_CAP_PEER_STATS (1ULL << 3)
#define BRUTAL_CAP_TC_AGGREGATE_MANAGER (1ULL << 4)
#define BRUTAL_CAP_PEER_BUDGET (1ULL << 5)
#define BRUTAL_CAP_PREFIX_INDEX (1ULL << 6)
#define BRUTAL_CAP_KERNEL_AGGREGATE (1ULL << 7)
#define BRUTAL_CAP_GENL (1ULL << 8)

struct brutal_info_v1
{
    __u16 size;
    __u16 abi_version;
    __u32 vendor_id;
    __u32 version;
    __u32 flags;
    __u64 capabilities;
    __u8 build_id[BRUTAL_BUILD_ID_LEN];
} __attribute__((packed));

#endif
