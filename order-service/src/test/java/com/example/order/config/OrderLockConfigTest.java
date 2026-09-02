package com.example.order.config;

import com.example.order.service.NoopLockStrategy;
import com.example.order.service.OrderLockStrategy;
import com.example.order.service.SynchronizedLockStrategy;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * OrderLockConfig（仿 CacheConfigTest 直接调工厂方法）：
 * - enabled=true 时返回 SynchronizedLockStrategy
 * - enabled=false 时返回 NoopLockStrategy
 */
class OrderLockConfigTest {

    private final OrderLockConfig orderLockConfig = new OrderLockConfig();

    @Test
    void enabledReturnsSynchronizedStrategy() {
        OrderLockProperties props = new OrderLockProperties();
        props.setEnabled(true);

        OrderLockStrategy strategy = orderLockConfig.orderLockStrategy(props);

        assertThat(strategy).isInstanceOf(SynchronizedLockStrategy.class);
    }

    @Test
    void disabledReturnsNoopStrategy() {
        OrderLockProperties props = new OrderLockProperties();
        props.setEnabled(false);

        OrderLockStrategy strategy = orderLockConfig.orderLockStrategy(props);

        assertThat(strategy).isInstanceOf(NoopLockStrategy.class);
    }

    @Test
    void enabledDefaultsTrue() {
        assertThat(new OrderLockProperties().isEnabled()).isTrue();
    }
}
