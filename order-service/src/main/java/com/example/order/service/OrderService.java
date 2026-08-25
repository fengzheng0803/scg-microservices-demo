package com.example.order.service;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.baomidou.mybatisplus.extension.plugins.pagination.Page;
import com.example.order.dto.CreateOrderRequest;
import com.example.order.entity.Order;
import com.example.order.mapper.OrderMapper;
import lombok.RequiredArgsConstructor;
import org.springframework.cache.annotation.CacheEvict;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;

import java.util.concurrent.ThreadLocalRandom;

@Service
@RequiredArgsConstructor
public class OrderService {

    private final OrderMapper orderMapper;

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

    @CacheEvict(cacheNames = "orders", key = "#id")
    public void delete(Long id) {
        orderMapper.deleteById(id);
    }

    /** 分页列表，按创建时间倒序 */
    public Page<Order> list(long page, long size) {
        return orderMapper.selectPage(new Page<>(page, size),
                new LambdaQueryWrapper<Order>().orderByDesc(Order::getCreateTime));
    }
}
