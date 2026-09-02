package com.example.order.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;

/** 订单锁开关，来源于 Nacos（order-service.yaml）并支持热刷新 */
@Data
@ConfigurationProperties(prefix = "order.lock")
public class OrderLockProperties {

    /** 加锁开关：true=synchronized 加锁，false=不加锁（@RefreshScope 工厂按此选择策略实现） */
    private boolean enabled = true;
}
