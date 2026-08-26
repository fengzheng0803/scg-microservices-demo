package com.example.gateway.config;

import org.springframework.cloud.gateway.filter.ratelimit.KeyResolver;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import reactor.core.publisher.Mono;

@Configuration
public class RateLimiterConfig {

    /** 限流维度：全局兜底桶（所有请求共享一个桶，容量 40/s + 20 突发） */
    @Bean
    public KeyResolver globalKeyResolver() {
        return exchange -> Mono.just("global");
    }
}
