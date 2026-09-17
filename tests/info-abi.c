#include <stddef.h>
#include <stdio.h>
#include "../brutal_uapi.h"

typedef char info_size_must_be_64[(sizeof(struct brutal_info_v1) == 64) ? 1 : -1];
typedef char build_id_must_be_40[(sizeof(((struct brutal_info_v1 *)0)->build_id) == 40) ? 1 : -1];
typedef char caps_offset_must_be_16[(offsetof(struct brutal_info_v1, capabilities) == 16) ? 1 : -1];
typedef char build_offset_must_be_24[(offsetof(struct brutal_info_v1, build_id) == 24) ? 1 : -1];

int main(void)
{
    if (TCP_BRUTAL_PARAMS != 23301 || TCP_BRUTAL_VERSION != 23302 ||
        TCP_BRUTAL_INFO != 23303 || BRUTAL_INFO_ABI_V1 != 1 ||
        BRUTAL_VENDOR_CUSTOM != 1)
        return 1;
    printf("brutal info ABI v1 size=%zu\n", sizeof(struct brutal_info_v1));
    return 0;
}
