// The congestion control: rate and cwnd, loss compensation, and the group clock
#include <linux/module.h>
#include <linux/math64.h>
#include "brutal.h"

#define MIN_PKT_INFO_SAMPLES 50
#define MIN_ACK_RATE_PERCENT 80

#define RESV_STALE_MIN_NS (2 * NSEC_PER_MSEC)
#define RESV_STALE_MAX_NS (20 * NSEC_PER_MSEC)
#define GROUP_MAX_LAG_NS (2 * NSEC_PER_MSEC)
#define RATE_UPDATE_INTERVAL_US 10000
#define RATE_UPDATE_TICK_US 100
#define RATE_UPDATE_INTERVAL_TICKS (RATE_UPDATE_INTERVAL_US / RATE_UPDATE_TICK_US)

static void brutal_update_rate_at(struct sock *sk, u32 sec, u16 now_tick)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct brutal *brutal = inet_csk_ca(sk);
    u16 sec_tag = sec;
    u64 acked = 0, losses = 0;
    u32 ack_rate;
    u64 rate, bdp, cwnd;
    u32 cwnd_gain;
    u16 generation = 0;
    int i;

    for (i = 0; i < PKT_INFO_SLOTS; i++)
    {
        if ((u16)(sec_tag - brutal->slot_secs[i]) <= PKT_INFO_SLOTS)
        {
            acked += brutal->slot_acked[i];
            losses += brutal->slot_losses[i];
        }
    }
    if (acked + losses < MIN_PKT_INFO_SAMPLES)
        ack_rate = 100;
    else
    {
        ack_rate = div64_u64(acked * 100, acked + losses);
        if (ack_rate < MIN_ACK_RATE_PERCENT)
            ack_rate = MIN_ACK_RATE_PERCENT;
    }
    brutal->ack_rate = ack_rate;

    if (brutal->group)
        brutal_group_get_config(brutal->group, &rate, &cwnd_gain, NULL,
                                &generation);
    else
    {
        rate = brutal->rate;
        cwnd_gain = brutal->cwnd_gain;
    }
    rate = div_u64(rate * 100, brutal->ack_rate);
    brutal->effective_rate = rate;
    brutal->last_update_tick = now_tick;
    brutal->seen_generation = generation;

    bdp = mul_u64_u64_div_u64(rate,
                              max_t(u32, tp->srtt_us >> 3, USEC_PER_MSEC),
                              USEC_PER_SEC);
    cwnd = div_u64(bdp * cwnd_gain, 10 * tp->mss_cache);
    cwnd = clamp_t(u64, cwnd, MIN_CWND,
                   min_t(u32, tp->snd_cwnd_clamp, INT_MAX));
    if (tp->snd_cwnd != cwnd)
        tp->snd_cwnd = cwnd;

    rate = min_t(u64, rate, READ_ONCE(sk->sk_max_pacing_rate));
    if (READ_ONCE(sk->sk_pacing_rate) != rate)
        WRITE_ONCE(sk->sk_pacing_rate, rate);
}

void brutal_update_rate(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    brutal_update_rate_at(sk, div_u64(tp->tcp_mstamp, USEC_PER_SEC),
                          (u16)div_u64(tp->tcp_mstamp, RATE_UPDATE_TICK_US));
}

static void brutal_maybe_update_rate(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct brutal *brutal = inet_csk_ca(sk);
    u16 now = (u16)div_u64(tp->tcp_mstamp, RATE_UPDATE_TICK_US);
    u16 generation = brutal->group ? brutal_group_generation(brutal->group) : 0;

    if (generation != brutal->seen_generation ||
        (u16)(now - brutal->last_update_tick) >= RATE_UPDATE_INTERVAL_TICKS)
        brutal_update_rate_at(sk, div_u64(tp->tcp_mstamp, USEC_PER_SEC), now);
}

static u32 brutal_burst_estimate(const struct sock *sk, u64 rate, u32 unsent)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    unsigned long bytes = rate >> READ_ONCE(sk->sk_pacing_shift);
    u32 segs;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 18, 0)
    u32 r = tcp_min_rtt(tp) >> READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_tso_rtt_log);
    if (r < BITS_PER_TYPE(sk->sk_gso_max_size))
        bytes += sk->sk_gso_max_size >> r;
#endif
    bytes = min_t(unsigned long, bytes, sk->sk_gso_max_size);
    segs = clamp_t(u32, bytes / tp->mss_cache, 2, sk->sk_gso_max_segs);
    segs = min(segs, tp->snd_cwnd - tcp_packets_in_flight(tp));
    unsent = min(unsent, tcp_wnd_end(tp) - tp->snd_nxt);
    return min_t(u32, segs * tp->mss_cache, unsent);
}

static void brutal_pacer_correct(struct brutal_pacer *p, s64 correction_ns)
{
    if (correction_ns >= 0)
        p->next_ns += correction_ns;
    else
        p->next_ns -= min_t(u64, p->next_ns, -correction_ns);
}

static u32 brutal_min_tso_segs(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct brutal *brutal = inet_csk_ca(sk);
    struct brutal_pacer *p = brutal->group;
    struct brutal_group *parent;
    u64 now = tp->tcp_clock_cache;
    u64 aggregate_rate, rate, start = 0, sent = 0;
    s64 correction_ns = 0, parent_correction_ns = 0;
    u32 old_parent_duration_ns = 0;
    u32 unsent, burst = 0, duration_ns = 0, parent_duration_ns = 0;
    bool settle = false;

    if (!p)
        return 2;

    brutal_maybe_update_rate(sk);
    rate = brutal->effective_rate;
    parent = p->parent;
    aggregate_rate = parent ? brutal_group_aggregate_rate(&parent->pacer) : 0;

    if (brutal->resv_bytes)
    {
        u64 used_ns;
        u32 stale_ns = clamp_t(u32,
                               max(brutal->resv_duration_ns,
                                   brutal->resv_parent_duration_ns) / 2,
                               RESV_STALE_MIN_NS, RESV_STALE_MAX_NS);

        sent = tp->bytes_sent - brutal->resv_bytes_sent;
        if (!sent && (s64)(now - brutal->resv_start_ns) < (s64)stale_ns)
        {
            if (tp->tcp_wstamp_ns < brutal->resv_start_ns)
                tp->tcp_wstamp_ns = brutal->resv_start_ns;
            return 2;
        }
        used_ns = div64_u64((u64)brutal->resv_duration_ns * sent,
                            brutal->resv_bytes);
        correction_ns = (s64)used_ns - (s64)brutal->resv_duration_ns;
        old_parent_duration_ns = brutal->resv_parent_duration_ns;
        if (old_parent_duration_ns)
        {
            used_ns = div64_u64((u64)old_parent_duration_ns * sent,
                                brutal->resv_bytes);
            parent_correction_ns =
                (s64)used_ns - (s64)old_parent_duration_ns;
        }
        settle = true;
        brutal->resv_bytes = 0;
        brutal->resv_parent_duration_ns = 0;
    }

    unsent = tp->write_seq - tp->snd_nxt;
    if (!unsent && tp->lost_out > tp->retrans_out)
        unsent = tp->mss_cache;
    if (unsent && tcp_packets_in_flight(tp) < tp->snd_cwnd &&
        after(tcp_wnd_end(tp), tp->snd_nxt))
    {
        burst = brutal_burst_estimate(sk, rate, unsent);
        duration_ns = div64_u64((u64)burst * NSEC_PER_SEC, rate);
        if (aggregate_rate)
            parent_duration_ns =
                div64_u64((u64)burst * NSEC_PER_SEC, aggregate_rate);
    }

    if (settle || burst)
    {
        bool use_parent = parent &&
                          (old_parent_duration_ns || parent_duration_ns);

        if (use_parent)
            spin_lock_bh(&parent->pacer.lock);
        spin_lock_bh(&p->lock);
        if (settle)
            brutal_pacer_correct(p, correction_ns);
        if (old_parent_duration_ns)
            brutal_pacer_correct(&parent->pacer, parent_correction_ns);
        if (burst)
        {
            start = max(p->next_ns, now - GROUP_MAX_LAG_NS);
            if (parent_duration_ns)
                start = max(start, parent->pacer.next_ns);
            p->next_ns = start + duration_ns;
            if (parent_duration_ns)
                parent->pacer.next_ns = start + parent_duration_ns;
        }
        spin_unlock_bh(&p->lock);
        if (use_parent)
            spin_unlock_bh(&parent->pacer.lock);
    }
    if (settle)
    {
        if (p->parent)
        {
            atomic64_add(sent, &p->sent_bytes);
            brutal_group_account_sent(p->parent, sent);
        }
        else
            brutal_group_account_sent(container_of(p, struct brutal_group, pacer), sent);
    }
    if (!burst)
        return 2;

    brutal->resv_start_ns = start;
    brutal->resv_bytes = burst;
    brutal->resv_duration_ns = duration_ns;
    brutal->resv_parent_duration_ns = parent_duration_ns;
    brutal->resv_bytes_sent = tp->bytes_sent;
    if (tp->tcp_wstamp_ns < start)
        tp->tcp_wstamp_ns = start;
    return 2;
}

static void brutal_init(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct brutal *brutal = inet_csk_ca(sk);

    brutal_sockopt_install(sk);
    tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;

    memset(brutal, 0, sizeof(*brutal));
    brutal->rate = INIT_PACING_RATE;
    brutal->cwnd_gain = INIT_CWND_GAIN;
    brutal->ack_rate = 100;

    brutal_apply_rule(sk, brutal);
    if (brutal->group)
        brutal_update_rate(sk);

    cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
}

void brutal_settle_reservation(struct sock *sk)
{
    struct brutal *brutal = inet_csk_ca(sk);
    struct brutal_pacer *p = brutal->group;

    if (p && brutal->resv_bytes)
    {
        struct brutal_group *parent = p->parent;
        u64 sent = tcp_sk(sk)->bytes_sent - brutal->resv_bytes_sent;
        u64 used_ns = div64_u64((u64)brutal->resv_duration_ns * sent,
                                brutal->resv_bytes);
        s64 correction_ns = (s64)used_ns - (s64)brutal->resv_duration_ns;
        s64 parent_correction_ns = 0;

        if (brutal->resv_parent_duration_ns)
        {
            used_ns = div64_u64((u64)brutal->resv_parent_duration_ns * sent,
                                brutal->resv_bytes);
            parent_correction_ns =
                (s64)used_ns - (s64)brutal->resv_parent_duration_ns;
            spin_lock_bh(&parent->pacer.lock);
        }
        spin_lock_bh(&p->lock);
        brutal_pacer_correct(p, correction_ns);
        if (brutal->resv_parent_duration_ns)
            brutal_pacer_correct(&parent->pacer, parent_correction_ns);
        spin_unlock_bh(&p->lock);
        if (brutal->resv_parent_duration_ns)
            spin_unlock_bh(&parent->pacer.lock);

        if (p->parent)
        {
            atomic64_add(sent, &p->sent_bytes);
            brutal_group_account_sent(p->parent, sent);
        }
        else
            brutal_group_account_sent(container_of(p, struct brutal_group, pacer), sent);
        brutal->resv_bytes = 0;
        brutal->resv_parent_duration_ns = 0;
    }
}

static void brutal_release(struct sock *sk)
{
    brutal_group_leave(sk);
    brutal_sockopt_uninstall(sk);
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0)
static void brutal_main(struct sock *sk, u32 ack, int flag,
                        const struct rate_sample *rs)
#else
static void brutal_main(struct sock *sk, const struct rate_sample *rs)
#endif
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct brutal *brutal = inet_csk_ca(sk);
    u32 sec, slot;
    u16 now_tick;

    if (rs->delivered < 0 || rs->interval_us <= 0)
        return;

    sec = div_u64(tp->tcp_mstamp, USEC_PER_SEC);
    slot = sec % PKT_INFO_SLOTS;

    if (brutal->slot_secs[slot] == (u16)sec)
    {
        brutal->slot_acked[slot] += rs->acked_sacked;
        brutal->slot_losses[slot] += rs->losses;
    }
    else
    {
        brutal->slot_secs[slot] = sec;
        brutal->slot_acked[slot] = rs->acked_sacked;
        brutal->slot_losses[slot] = rs->losses;
    }

    now_tick = (u16)div_u64(tp->tcp_mstamp, RATE_UPDATE_TICK_US);
    if ((u16)(now_tick - brutal->last_update_tick) >= RATE_UPDATE_INTERVAL_TICKS ||
        (brutal->group && brutal_group_generation(brutal->group) !=
                              brutal->seen_generation))
        brutal_update_rate_at(sk, sec, now_tick);
}

static u32 brutal_undo_cwnd(struct sock *sk)
{
    return tcp_sk(sk)->snd_cwnd;
}

static u32 brutal_ssthresh(struct sock *sk)
{
    return tcp_sk(sk)->snd_ssthresh;
}

struct tcp_congestion_ops tcp_brutal_ops = {
    .flags = TCP_CONG_NON_RESTRICTED,
    .name = "brutal",
    .owner = THIS_MODULE,
    .init = brutal_init,
    .release = brutal_release,
    .cong_control = brutal_main,
    .undo_cwnd = brutal_undo_cwnd,
    .ssthresh = brutal_ssthresh,
    .min_tso_segs = brutal_min_tso_segs,
};

static int __init brutal_register(void)
{
    int ret;

    BUILD_BUG_ON(sizeof(struct brutal) > ICSK_CA_PRIV_SIZE);
    BUILD_BUG_ON(sizeof(struct brutal_params) != 20);
    BUILD_BUG_ON(sizeof(struct brutal_info_v1) != 64);
    BUILD_BUG_ON(sizeof(BRUTAL_BUILD_ID) - 1 != BRUTAL_BUILD_ID_LEN);

    ret = brutal_sockopt_init();
    if (ret)
        return ret;
    ret = brutal_rules_init();
    if (ret)
    {
        brutal_sockopt_exit();
        return ret;
    }
    ret = brutal_genl_init();
    if (ret)
    {
        brutal_rules_exit();
        brutal_sockopt_exit();
        return ret;
    }
    ret = tcp_register_congestion_control(&tcp_brutal_ops);
    if (ret)
    {
        brutal_genl_exit();
        brutal_rules_exit();
        brutal_sockopt_exit();
    }
    return ret;
}

static void __exit brutal_unregister(void)
{
    tcp_unregister_congestion_control(&tcp_brutal_ops);
    brutal_genl_exit();
    brutal_rules_exit();
    brutal_sockopt_exit();
}

module_init(brutal_register);
module_exit(brutal_unregister);

MODULE_AUTHOR("The Hysteria Project");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("TCP Brutal");
MODULE_VERSION(__stringify(BRUTAL_VERSION_MAJOR) "." __stringify(BRUTAL_VERSION_MINOR) "." __stringify(BRUTAL_VERSION_PATCH));
