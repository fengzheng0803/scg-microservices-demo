package com.example.order.service;

import java.math.BigDecimal;
import java.util.concurrent.ThreadLocalRandom;

import org.springframework.cache.annotation.CacheEvict;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.baomidou.mybatisplus.extension.plugins.pagination.Page;
import com.example.order.dto.CreateOrderRequest;
import com.example.order.entity.Order;
import com.example.order.mapper.OrderMapper;

import lombok.RequiredArgsConstructor;

@Service
@RequiredArgsConstructor
public class OrderService {

    private final OrderMapper orderMapper;

    private final OrderLockStrategy lockStrategy;

    /** 创建订单：雪花 ID + 时间戳订单号 */
    public Order create(CreateOrderRequest request) {
        Order order = new Order();
        order.setOrderNo("ORD" + System.currentTimeMillis()
                + ThreadLocalRandom.current().nextInt(1000, 9999));
        order.setUserId(request.userId());
        order.setProductName(request.productName());
        order.setAmount(request.amount());
        order.setStatus(0);
        orderMapper.insert(order);
        return order;
    }

    @Cacheable(cacheNames = "orders", key = "#id")
    public Order get(Long id) {
        return orderMapper.selectById(id);
    }

    /** 慢库模拟版：与 get 共享 orders 缓存——HIT 不落库（无 SLEEP），MISS 时查询强制阻塞 50ms */
    @Cacheable(cacheNames = "orders", key = "#id")
    public Order getSlow(Long id) {
        return orderMapper.selectByIdWithDelay(id);
    }

    @CacheEvict(cacheNames = "orders", key = "#id")
    public void delete(Long id) {
        orderMapper.deleteById(id);
    }

    /** 修改订单金额（delta 语义）：读-改-写整体在锁策略临界区内执行——加锁/不加锁由 Nacos 标志决定，订单不存在返回 null */
    @CacheEvict(cacheNames = "orders", key = "#id")
    public Order updateAmount(Long id, BigDecimal delta) {
        return lockStrategy.execute(() -> {
            Order order = orderMapper.selectById(id);
            if (order == null) {
                return null;
            }
            order.setAmount(order.getAmount().add(delta));
            orderMapper.updateById(order);
            return order;
        });
    }

    /** 分页列表，按创建时间倒序 */
    public Page<Order> list(long page, long size) {
        return orderMapper.selectPage(new Page<>(page, size),
                new LambdaQueryWrapper<Order>().orderByDesc(Order::getCreateTime));
    }
}
