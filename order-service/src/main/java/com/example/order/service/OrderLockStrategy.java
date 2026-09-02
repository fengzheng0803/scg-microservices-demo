package com.example.order.service;

import java.util.function.Supplier;

/**
 * 订单修改操作的锁策略（Nacos 标志 order.lock.enabled 决定注入哪种实现）：
 * execute 内包裹需要互斥的临界区代码，回调形态保证锁贯穿整个临界区
 * （拆成 lock()/unlock() 两个调用时 synchronized 方法返回即释放监视器，锁不住中间代码）。
 */
public interface OrderLockStrategy {

    <T> T execute(Supplier<T> criticalSection);
}
