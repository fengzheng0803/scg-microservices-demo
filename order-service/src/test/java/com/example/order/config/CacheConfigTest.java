package com.example.order.config;

import com.example.order.entity.Order;
import org.junit.jupiter.api.Test;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;

import static org.assertj.core.api.Assertions.assertThat;

class CacheConfigTest {

    private final CacheConfig cacheConfig = new CacheConfig();

    @Test
    void cacheHitsAfterPut() {
        OrderCacheProperties props = new OrderCacheProperties();
        CacheManager cacheManager = cacheConfig.cacheManager(props);
        Cache cache = cacheManager.getCache("orders");
        Order order = new Order();
        order.setId(1L);

        cache.put(1L, order);

        assertThat(cache.get(1L)).isNotNull();
    }

    @Test
    void maxSizeFromPropertiesEvictsOldest() {
        OrderCacheProperties props = new OrderCacheProperties();
        props.setMaxSize(1);
        Cache cache = cacheConfig.cacheManager(props).getCache("orders");
        Order first = new Order();
        first.setId(1L);
        Order second = new Order();
        second.setId(2L);

        cache.put(1L, first);
        cache.put(2L, second);

        // Caffeine 超容量驱逐是异步的（executor 维护），cleanUp() 同步执行维护后再断言，
        // 否则紧跟 put 的 get 仍能看到被驱逐条目（brief 原样测试在此处必然失败）
        ((com.github.benmanes.caffeine.cache.Cache<?, ?>) cache.getNativeCache()).cleanUp();

        assertThat(cache.get(1L)).isNull();
        assertThat(cache.get(2L)).isNotNull();
    }
}
