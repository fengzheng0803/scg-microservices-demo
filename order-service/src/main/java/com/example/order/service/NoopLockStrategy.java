package com.example.order.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.function.Supplier;

/** 不加锁实现：临界区直接执行，无互斥（并发下暴露竞态，用于对比验证） */
public class NoopLockStrategy implements OrderLockStrategy {

    private static final Logger log = LoggerFactory.getLogger(NoopLockStrategy.class);

    @Override
    public <T> T execute(Supplier<T> criticalSection) {
        log.debug("[lock] 不加锁直行临界区 thread={}", Thread.currentThread().getName());
        return criticalSection.get();
    }
}
