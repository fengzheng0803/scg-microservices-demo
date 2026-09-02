package com.example.order.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.function.Supplier;

/**
 * 加锁实现：synchronized 方法包裹执行，临界区在监视器持有期内完成。
 * 锁粒度为全局单监视器（所有订单共一把锁）——分段锁留作后续扩展。
 * 监视器是内存态，仅单实例内有效。
 */
public class SynchronizedLockStrategy implements OrderLockStrategy {

    private static final Logger log = LoggerFactory.getLogger(SynchronizedLockStrategy.class);

    @Override
    public synchronized <T> T execute(Supplier<T> criticalSection) {
        log.debug("[lock] synchronized 加锁执行临界区 thread={}", Thread.currentThread().getName());
        return criticalSection.get();
    }
}
