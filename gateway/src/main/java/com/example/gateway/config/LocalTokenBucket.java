package com.example.gateway.config;

import java.util.concurrent.atomic.AtomicReference;
import java.util.function.LongSupplier;

/**
 * 本地内存令牌桶（Task 12 兜底限流本地化，替代 Redis EVAL）：
 *
 * - refill 数学与旧 Lua / nginx token_bucket 同构：tokens += elapsed×rate，封顶 capacity；
 * - CAS 循环保证 refill+扣减原子（无锁，Reactor 事件循环线程安全，无 lost update）；
 * - 时钟用 System.nanoTime（单调时钟）——不受 Docker VM 墙钟回跳影响
 *   （旧 Redis Lua 传墙钟 currentTimeMillis 会被回跳打断 refill）；
 * - 无 I/O、无故障模式：不再需要 fail-open 分支。
 */
public final class LocalTokenBucket {

    /** 桶状态：剩余 token（可为小数）+ 上次 refill 的纳秒时间戳 */
    private record State(double tokens, long lastRefillNs) {
    }

    /** 判定结果：是否放行 + 判定后剩余 token（供 X-RateLimit-Remaining） */
    public record AcquireResult(boolean allowed, long remainingTokens) {
    }

    private final double ratePerSecond;
    private final double capacity;
    private final LongSupplier nanoTime;
    private final AtomicReference<State> state;

    public LocalTokenBucket(double ratePerSecond, double capacity) {
        this(ratePerSecond, capacity, System::nanoTime);
    }

    /** 测试注入假时钟用 */
    LocalTokenBucket(double ratePerSecond, double capacity, LongSupplier nanoTime) {
        this.ratePerSecond = ratePerSecond;
        this.capacity = capacity;
        this.nanoTime = nanoTime;
        this.state = new AtomicReference<>(new State(capacity, nanoTime.getAsLong()));
    }

    /**
     * 尝试扣减 1 token。被拒时不动状态：refill 数学是 (storedTokens, storedTs, now)
     * 的纯函数，下次调用重算结果一致，拒绝风暴下零写入。
     */
    public AcquireResult tryAcquire() {
        long now = nanoTime.getAsLong();
        while (true) {
            State cur = state.get();
            double tokens = Math.min(capacity,
                    cur.tokens() + (now - cur.lastRefillNs()) / 1_000_000.0 * ratePerSecond / 1000.0);
            if (tokens < 1) {
                return new AcquireResult(false, (long) tokens);
            }
            State next = new State(tokens - 1, now);
            if (state.compareAndSet(cur, next)) {
                return new AcquireResult(true, (long) (tokens - 1));
            }
        }
    }
}
