package com.example.order.config;

import org.junit.jupiter.api.Test;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.cache.support.NoOpCacheManager;
import org.springframework.data.redis.cache.RedisCacheManager;
import org.springframework.data.redis.connection.RedisConnectionFactory;

import java.time.Duration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/**
 * CacheConfig（Task 12：Caffeine→Redis）：
 * - enabled=true 时返回 RedisCacheManager，cacheDefaults TTL 取属性值
 * - enabled=false 时返回 NoOpCacheManager（@Cacheable 直通落库）
 * 不触发真实 Redis 连接：RedisCacheManager 构造仅保存配置，连接在首次读写时建立。
 */
class CacheConfigTest {

    private final CacheConfig cacheConfig = new CacheConfig();
    private final RedisConnectionFactory connectionFactory = mock(RedisConnectionFactory.class);

    @Test
    void enabledReturnsRedisCacheManagerWithTtlFromProperties() {
        OrderCacheProperties props = new OrderCacheProperties();
        props.setTtl(Duration.ofSeconds(11));

        CacheManager cacheManager = cacheConfig.cacheManager(props, connectionFactory);

        assertThat(cacheManager).isInstanceOf(RedisCacheManager.class);
        RedisCacheManager redisManager = (RedisCacheManager) cacheManager;
        // getCache 不建立连接，仅按 cacheDefaults 惰性创建 Cache 句柄；
        // 配置表在首次 getCache 后才登记该 cacheName，断言顺序不能颠倒
        Cache cache = redisManager.getCache("orders");
        assertThat(cache).isNotNull();
        assertThat(cache.getName()).isEqualTo("orders");
        assertThat(redisManager.getCacheConfigurations().get("orders")
                .getTtl()).isEqualTo(Duration.ofSeconds(11));
    }

    @Test
    void disabledReturnsNoOpManager() {
        OrderCacheProperties props = new OrderCacheProperties();
        props.setEnabled(false);

        CacheManager cacheManager = cacheConfig.cacheManager(props, connectionFactory);

        assertThat(cacheManager).isInstanceOf(NoOpCacheManager.class);
        // NoOp：不查缓存、不写缓存——控制器 X-Cache 恒 MISS，请求直通 DB
        Cache cache = cacheManager.getCache("orders");
        assertThat(cache).isNotNull();
        cache.put(1L, new Object());
        assertThat(cache.get(1L)).isNull();
    }

    @Test
    void enabledDefaultsTrue() {
        OrderCacheProperties props = new OrderCacheProperties();
        assertThat(props.isEnabled()).isTrue();
    }

    /**
     * 序列化往返回归测试：缓存写入 Order 后反序列化必须还原为 Order 而非 LinkedHashMap
     * （default typing 丢失时 GenericJackson2JsonRedisSerializer 会退化为 Map，实测曾引发
     * 缓存命中时 ClassCastException）。纯内存往返，不依赖 Redis。
     */
    @Test
    void orderSerializationRoundTripPreservesType() {
        org.springframework.data.redis.serializer.RedisSerializer<Object> serializer =
                CacheConfig.orderValueSerializer();

        com.example.order.entity.Order order = new com.example.order.entity.Order();
        order.setId(42L);
        order.setOrderNo("ORD-TEST-42");
        order.setCreateTime(java.time.LocalDateTime.of(2026, 8, 28, 12, 0));

        byte[] bytes = serializer.serialize(order);
        assertThat(bytes).isNotNull();
        Object restored = serializer.deserialize(bytes);

        assertThat(restored).isInstanceOf(com.example.order.entity.Order.class);
        assertThat(((com.example.order.entity.Order) restored).getId()).isEqualTo(42L);
        assertThat(((com.example.order.entity.Order) restored).getCreateTime())
                .isEqualTo(java.time.LocalDateTime.of(2026, 8, 28, 12, 0));
    }
}
