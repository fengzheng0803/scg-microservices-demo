package com.example.order.service;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 锁策略行为测试：
 * - synchronized 版：并发临界区必须互斥（共享计数器无丢失更新）
 * - noop 版：临界区直接执行并返回结果
 */
class OrderLockStrategyTest {

    @Test
    void synchronizedStrategySerializesConcurrentCriticalSections() throws Exception {
        OrderLockStrategy strategy = new SynchronizedLockStrategy();
        int[] counter = {0};
        int threads = 8;
        int increments = 1000;
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        CountDownLatch start = new CountDownLatch(1);
        List<Future<?>> futures = new ArrayList<>();
        for (int i = 0; i < threads; i++) {
            futures.add(pool.submit(() -> {
                start.await();
                for (int j = 0; j < increments; j++) {
                    strategy.execute(() -> {
                        counter[0]++;
                        return null;
                    });
                }
                return null;
            }));
        }
        start.countDown();
        for (Future<?> future : futures) {
            future.get();
        }
        pool.shutdown();

        assertThat(counter[0]).isEqualTo(threads * increments);
    }

    @Test
    void noopStrategyExecutesSectionAndReturnsResult() {
        OrderLockStrategy strategy = new NoopLockStrategy();

        assertThat(strategy.execute(() -> "ok")).isEqualTo("ok");
    }
}
