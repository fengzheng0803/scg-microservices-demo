package com.example.order.controller;

import com.baomidou.mybatisplus.extension.plugins.pagination.Page;
import com.example.order.dto.CreateOrderRequest;
import com.example.order.entity.Order;
import com.example.order.service.OrderService;
import lombok.RequiredArgsConstructor;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;

@RestController
@RequestMapping("/orders")
@RequiredArgsConstructor
public class OrderController {

    private final OrderService orderService;

    private final CacheManager cacheManager;

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Order create(@RequestBody CreateOrderRequest request) {
        return orderService.create(request);
    }

    @GetMapping("/{id}")
    public ResponseEntity<Order> get(@PathVariable Long id) {
        Cache cache = cacheManager.getCache("orders");
        boolean hit = cache != null && cache.get(id) != null;
        Order order = orderService.get(id);
        if (order == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok()
                .header("X-Cache", hit ? "HIT" : "MISS")
                .body(order);
    }

    /** 慢库模拟端点：与 /orders/{id} 共享缓存，MISS 落库时 SQL 强制 SLEEP 50ms */
    @GetMapping("/slow/{id}")
    public ResponseEntity<Order> getSlow(@PathVariable Long id) {
        Cache cache = cacheManager.getCache("orders");
        boolean hit = cache != null && cache.get(id) != null;
        Order order = orderService.getSlow(id);
        if (order == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok()
                .header("X-Cache", hit ? "HIT" : "MISS")
                .body(order);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id) {
        orderService.delete(id);
    }

    /** 修改订单金额（delta 语义：读-改-写，加锁/不加锁由 Nacos order.lock.enabled 热切换决定） */
    @PatchMapping("/{id}/amount")
    public ResponseEntity<Order> updateAmount(@PathVariable Long id,
                                              @RequestParam BigDecimal delta) {
        Order order = orderService.updateAmount(id, delta);
        if (order == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok(order);
    }

    @GetMapping
    public Page<Order> list(@RequestParam(defaultValue = "1") long page,
                            @RequestParam(defaultValue = "10") long size) {
        return orderService.list(page, size);
    }
}
