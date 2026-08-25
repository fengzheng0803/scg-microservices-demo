package com.example.order.dto;

import java.math.BigDecimal;

/** 创建订单请求体 */
public record CreateOrderRequest(Long userId, String productName, BigDecimal amount) {
}
