package com.example.order.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** 订单缓存参数，来源于 Nacos（order-service.yaml）并支持热刷新 */
@Data
@ConfigurationProperties(prefix = "order.cache")
public class OrderCacheProperties {

    /** 缓存开关：false 时 @Cacheable 直通落库（B 相位无缓存容量压测用，经 Nacos 热切换） */
    private boolean enabled = true;

    /** 缓存过期时间 */
    private Duration ttl = Duration.ofSeconds(60);

    /** 最大条目数（Caffeine 时代遗留：Redis 无条目数上限，保留仅为兼容旧 Nacos 配置） */
    private int maxSize = 100;
}
