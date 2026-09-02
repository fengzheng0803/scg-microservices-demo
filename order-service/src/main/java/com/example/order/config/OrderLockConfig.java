package com.example.order.config;

import com.example.order.service.NoopLockStrategy;
import com.example.order.service.OrderLockStrategy;
import com.example.order.service.SynchronizedLockStrategy;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.cloud.context.config.annotation.RefreshScope;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * 订单锁策略工厂（与 CacheConfig 的 cacheManager 同构）：
 * @RefreshScope 放在策略 Bean 上——Nacos 推 order.lock.enabled 变更时该 Bean
 * 代理销毁旧实例，下次访问按新标志重建，实现加锁/不加锁逻辑热切换（无需重建）。
 * 注意声明返回 OrderLockStrategy 接口——@RefreshScope 默认按接口生成 JDK 代理。
 */
@Configuration
public class OrderLockConfig {

    /** 注册为 Bean 才能被策略工厂注入，且刷新时重新绑定 */
    @Bean
    @ConfigurationProperties(prefix = "order.lock")
    public OrderLockProperties orderLockProperties() {
        return new OrderLockProperties();
    }

    @Bean
    @RefreshScope
    public OrderLockStrategy orderLockStrategy(OrderLockProperties properties) {
        return properties.isEnabled() ? new SynchronizedLockStrategy() : new NoopLockStrategy();
    }
}
