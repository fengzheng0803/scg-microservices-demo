package com.example.order.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** 订单缓存参数，来源于 Nacos（order-service.yaml）并支持热刷新 */
@Data
@ConfigurationProperties(prefix = "order.cache")
public class OrderCacheProperties {

    /** 缓存过期时间 */
    private Duration ttl = Duration.ofSeconds(60);

    /** 最大条目数 */
    private int maxSize = 100;
}
