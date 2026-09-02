package com.example.gateway.config;

import org.junit.jupiter.api.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * LocalTokenBucket（Task 12 兜底限流本地化）：
 * - 冷启动发放整桶 CAP（保突发语义，与旧 Redis Lua 一致）
 * - refill 数学 = tokens + elapsed×rate，封顶 CAP
 * - CAS 保证 refill+扣减原子（并发无 lost update）
 * - 与旧 SCG RedisRateLimiter 不同：burst < rate 是合法配置（无硬断言）
 */
class LocalTokenBucketTest {

    /** 假时钟：测试里手动推进纳秒，System.nanoTime 单调时钟的生产实现不受墙钟回跳影响 */
    private final AtomicLong clock = new AtomicLong(0);

    private LocalTokenBucket bucket(double rate, double capacity) {
        return new LocalTokenBucket(rate, capacity, clock::get);
    }

    @Test
    void coldStartGrantsFullBurstCapacity() {
        LocalTokenBucket b = bucket(40, 40);
        int allowed = 0;
        for (int i = 0; i < 41; i++) {
            if (b.tryAcquire().allowed()) {
                allowed++;
            }
        }
        assertThat(allowed).isEqualTo(40);
    }

    @Test
    void refillsTokensAtConfiguredRate() {
        LocalTokenBucket b = bucket(10, 20);
        for (int i = 0; i < 20; i++) {
            assertThat(b.tryAcquire().allowed()).isTrue();
        }
        assertThat(b.tryAcquire().allowed()).isFalse();

        clock.addAndGet(100_000_000);   // +100ms → 10/s × 0.1s = 1 token
        assertThat(b.tryAcquire().allowed()).isTrue();
        assertThat(b.tryAcquire().allowed()).isFalse();

        clock.addAndGet(500_000_000);   // +500ms → +5 tokens
        int allowed = 0;
        for (int i = 0; i < 6; i++) {
            if (b.tryAcquire().allowed()) {
                allowed++;
            }
        }
        assertThat(allowed).isEqualTo(5);
    }

    @Test
    void refillIsCappedAtCapacity() {
        LocalTokenBucket b = bucket(10, 20);
        for (int i = 0; i < 20; i++) {
            b.tryAcquire();
        }
        clock.addAndGet(10_000_000_000L);   // +10s → 理论补 100，封顶 20

        int allowed = 0;
        for (int i = 0; i < 21; i++) {
            if (b.tryAcquire().allowed()) {
                allowed++;
            }
        }
        assertThat(allowed).isEqualTo(20);
    }

    @Test
    void burstBelowRateIsLegalConfiguration() {
        // 旧 SCG RedisRateLimiter 断言 burst >= rate；本地桶无此约束，40/20 合法：
        // 突发只封顶在 20，但每秒可补 40 个
        LocalTokenBucket b = bucket(40, 20);
        int allowed = 0;
        for (int i = 0; i < 21; i++) {
            if (b.tryAcquire().allowed()) {
                allowed++;
            }
        }
        assertThat(allowed).isEqualTo(20);

        clock.addAndGet(100_000_000);   // +100ms → 40/s × 0.1s = 4 tokens
        allowed = 0;
        for (int i = 0; i < 5; i++) {
            if (b.tryAcquire().allowed()) {
                allowed++;
            }
        }
        assertThat(allowed).isEqualTo(4);
    }

    @Test
    void concurrentAcquiresNeverExceedCapacity() throws InterruptedException {
        // 时钟冻结：并发下最多只有 CAP 次成功（CAS 防 lost update 的证明）
        LocalTokenBucket b = bucket(40, 40);
        int threads = 8;
        int perThread = 25;
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(threads);
        AtomicInteger allowed = new AtomicInteger();

        for (int t = 0; t < threads; t++) {
            new Thread(() -> {
                try {
                    start.await();
                    for (int i = 0; i < perThread; i++) {
                        if (b.tryAcquire().allowed()) {
                            allowed.incrementAndGet();
                        }
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    done.countDown();
                }
            }).start();
        }
        start.countDown();
        done.await();

        assertThat(allowed.get()).isEqualTo(40);
    }

    @Test
    void reportsRemainingTokensAfterAcquire() {
        LocalTokenBucket b = bucket(10, 20);
        LocalTokenBucket.AcquireResult first = b.tryAcquire();
        assertThat(first.allowed()).isTrue();
        assertThat(first.remainingTokens()).isEqualTo(19);
    }
}
