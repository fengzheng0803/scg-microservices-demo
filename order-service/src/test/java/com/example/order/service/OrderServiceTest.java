package com.example.order.service;

import com.example.order.dto.CreateOrderRequest;
import com.example.order.entity.Order;
import com.example.order.mapper.OrderMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class OrderServiceTest {

    @Mock
    private OrderMapper orderMapper;

    @Mock
    private OrderLockStrategy lockStrategy;

    @InjectMocks
    private OrderService orderService;

    private CreateOrderRequest request;

    @BeforeEach
    void setUp() {
        request = new CreateOrderRequest(1L, "机械键盘", new BigDecimal("399.00"));
    }

    @Test
    void createGeneratesOrderNoAndInsertsWithStatusZero() {
        when(orderMapper.insert(any(Order.class))).thenReturn(1);

        Order created = orderService.create(request);

        assertThat(created.getOrderNo()).startsWith("ORD");
        assertThat(created.getStatus()).isZero();
        assertThat(created.getUserId()).isEqualTo(1L);
        assertThat(created.getAmount()).isEqualByComparingTo("399.00");
        verify(orderMapper).insert(any(Order.class));
    }

    @Test
    void getReturnsOrderFromMapper() {
        Order order = new Order();
        order.setId(100L);
        when(orderMapper.selectById(100L)).thenReturn(order);

        assertThat(orderService.get(100L)).isSameAs(order);
    }

    @Test
    void getSlowDelegatesToMapperWithDelay() {
        Order order = new Order();
        order.setId(100L);
        when(orderMapper.selectByIdWithDelay(100L)).thenReturn(order);

        assertThat(orderService.getSlow(100L)).isSameAs(order);
    }

    @Test
    void deleteCallsMapper() {
        orderService.delete(7L);

        verify(orderMapper).deleteById(7L);
    }

    @Test
    void updateAmountAppliesDeltaAndWritesBack() {
        OrderService service = new OrderService(orderMapper, new SynchronizedLockStrategy());
        Order order = new Order();
        order.setId(100L);
        order.setAmount(new BigDecimal("50.00"));
        when(orderMapper.selectById(100L)).thenReturn(order);

        Order updated = service.updateAmount(100L, new BigDecimal("-1.00"));

        assertThat(updated.getAmount()).isEqualByComparingTo("49.00");
        verify(orderMapper).updateById(order);
    }

    @Test
    void updateAmountReturnsNullWhenOrderMissing() {
        OrderService service = new OrderService(orderMapper, new NoopLockStrategy());
        when(orderMapper.selectById(999L)).thenReturn(null);

        assertThat(service.updateAmount(999L, new BigDecimal("1.00"))).isNull();
        verify(orderMapper, never()).updateById(any(Order.class));
    }
}
