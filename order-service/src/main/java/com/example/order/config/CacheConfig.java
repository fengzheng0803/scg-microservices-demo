package com.example.order.config;

import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.cache.CacheManager;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cache.caffeine.CaffeineCacheManager;
import org.springframework.cloud.context.config.annotation.RefreshScope;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableCaching
public class CacheConfig {

    @Bean
    @ConfigurationProperties(prefix = "order.cache")
    public OrderCacheProperties orderCacheProperties() {
        return new OrderCacheProperties();
    }

    /**
     * @RefreshScope 放在 @Bean 方法上：Nacos 配置变更刷新事件触发时
     * 会用新参数重建 CacheManager，实现缓存 TTL/容量热刷新
     */
    @Bean
    @RefreshScope
    public CacheManager cacheManager(OrderCacheProperties properties) {
        CaffeineCacheManager manager = new CaffeineCacheManager("orders");
        manager.setCaffeine(Caffeine.newBuilder()
                .expireAfterWrite(properties.getTtl())
                .maximumSize(properties.getMaxSize()));
        return manager;
    }
}
