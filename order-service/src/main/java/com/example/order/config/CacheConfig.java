package com.example.order.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.cache.CacheManager;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cache.support.NoOpCacheManager;
import org.springframework.cloud.context.config.annotation.RefreshScope;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.cache.RedisCacheConfiguration;
import org.springframework.data.redis.cache.RedisCacheManager;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.RedisSerializationContext;
import org.springframework.data.redis.serializer.StringRedisSerializer;

/**
 * 缓存：Redis 分布式缓存（Task 12 由 Caffeine 本地缓存改为 Redis）。
 *
 * - order.cache.enabled=false 时返回 NoOpCacheManager：@Cacheable 直通落库，
 *   不查不写 Redis。B 相位「无缓存容量」压测经 Nacos 热切换此开关（无需重建）。
 * - @RefreshScope 放在 cacheManager Bean 上：Nacos 配置变更（ttl/enabled）时该
 *   Bean 代理销毁旧实例，下次访问用新参数重建，实现缓存参数热刷新。
 *   注意声明返回 CacheManager 接口——@RefreshScope 默认按接口生成 JDK 代理，
 *   NoOpCacheManager 是 final 类也无碍。
 * - maxSize 是 Caffeine 时代遗留字段：Redis 无条目数上限（容量由 Redis 内存
 *   策略控制），保留仅为兼容旧 Nacos 配置，不参与 Redis 缓存构造。
 */
@Configuration
@EnableCaching
public class CacheConfig {

    /** 注册为 Bean 才能被 cacheManager 注入，且刷新时被 ConfigurationPropertiesRebinder 重新绑定 */
    @Bean
    @ConfigurationProperties(prefix = "order.cache")
    public OrderCacheProperties orderCacheProperties() {
        return new OrderCacheProperties();
    }

    /**
     * 值序列化器：JSON + @class 类型信息（反序列化还原 Order）。
     * 必须注册 JavaTimeModule（Order.createTime 为 LocalDateTime，默认 ObjectMapper 会炸），
     * 且关闭 WRITE_DATES_AS_TIMESTAMPS（数组形式反序列化无法还原类型）。
     * 注意：activateDefaultTyping(NON_FINAL) 必须显式开启——传自定义 mapper 的构造器
     * 不会自动启用 default typing（只有无参构造器会），否则反序列化得到 LinkedHashMap
     * 而非 Order（实测：缓存命中时 ClassCastException）。
     * 独立成方法供 CacheConfigTest 做纯内存序列化往返回归测试。
     */
    static GenericJackson2JsonRedisSerializer orderValueSerializer() {
        ObjectMapper objectMapper = new ObjectMapper()
                .registerModule(new JavaTimeModule())
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
                .activateDefaultTyping(
                        com.fasterxml.jackson.databind.jsontype.impl.LaissezFaireSubTypeValidator.instance,
                        ObjectMapper.DefaultTyping.NON_FINAL,
                        com.fasterxml.jackson.annotation.JsonTypeInfo.As.PROPERTY);
        return new GenericJackson2JsonRedisSerializer(objectMapper);
    }

    @Bean
    @RefreshScope
    public CacheManager cacheManager(OrderCacheProperties properties,
                                     RedisConnectionFactory connectionFactory) {
        if (!properties.isEnabled()) {
            return new NoOpCacheManager();
        }
        RedisCacheConfiguration config = RedisCacheConfiguration.defaultCacheConfig()
                .entryTtl(properties.getTtl())
                .serializeKeysWith(RedisSerializationContext.SerializationPair
                        .fromSerializer(new StringRedisSerializer()))
                .serializeValuesWith(RedisSerializationContext.SerializationPair
                        .fromSerializer(orderValueSerializer()));
        return RedisCacheManager.builder(connectionFactory)
                .cacheDefaults(config)
                .build();
    }
}
