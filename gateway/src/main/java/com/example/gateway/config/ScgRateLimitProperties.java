package com.example.gateway.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * SCG 全局兜底桶参数（由 EdgeRateLimitBackstopFilter 读取，Task 12 本地化后为内存桶）。
 *
 * 值来自环境变量占位符（application.yml + compose 注入），默认 40/40（历史裁决
 * 终裁 v2 的数值，见 tasks-7-8 计划 R2）。本地桶无 RedisRateLimiter 的
 * burstCapacity >= replenishRate 硬断言，burst < rate 也合法（如 40/20，突发封顶 20）。
 * 容量态压测经 SCG_RATE_LIMIT_RPS / SCG_RATE_LIMIT_BURST 放大（如 100000/200000）。
 */
@Component   // @ConfigurationProperties 本身不注册 Bean，这里显式注册供 EdgeRateLimitBackstopFilter 注入
@ConfigurationProperties(prefix = "scg.rate-limit")
public class ScgRateLimitProperties {

    /** 每秒补充 token 数（replenishRate） */
    private int replenishRate = 40;

    /** 桶容量（burstCapacity） */
    private int burstCapacity = 40;

    public int getReplenishRate() {
        return replenishRate;
    }

    public void setReplenishRate(int replenishRate) {
        this.replenishRate = replenishRate;
    }

    public int getBurstCapacity() {
        return burstCapacity;
    }

    public void setBurstCapacity(int burstCapacity) {
        this.burstCapacity = burstCapacity;
    }
}
