package com.example.gateway.config;

import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.http.server.reactive.MockServerHttpResponse;
import org.springframework.mock.web.server.MockServerWebExchange;
import reactor.core.publisher.Mono;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * EdgeRateLimitBackstopFilter（Task 12 兜底限流本地化）：
 * - 带 X-Edge-RateLimited 头 → 跳过限流（本地桶不被扣减）
 * - 无头 → 本地内存令牌桶判定；有 token 放行 / 无 token 回 429
 * - 不再依赖 Redis：无 EVAL、无 fail-open 分支（本地桶无"故障"概念）
 */
class EdgeRateLimitBackstopFilterTest {

    private final GatewayFilterChain chain = mock(GatewayFilterChain.class);

    private EdgeRateLimitBackstopFilter filter(LocalTokenBucket bucket) {
        return new EdgeRateLimitBackstopFilter(bucket);
    }

    private MockServerWebExchange exchange(String... headers) {
        MockServerHttpRequest.BaseBuilder<?> b = MockServerHttpRequest.get("/api/order/orders?page=1&size=1");
        for (String h : headers) {
            b.header(h, "1");
        }
        return MockServerWebExchange.from(b);
    }

    @Test
    void skipsRateLimitWhenEdgeHeaderPresent() {
        when(chain.filter(any())).thenReturn(Mono.empty());
        // 容量 0 的桶：任何无头请求都会被拒——带头请求却必须放行，证明跳过时桶未被触碰
        EdgeRateLimitBackstopFilter f = filter(new LocalTokenBucket(0, 0, System::nanoTime));

        f.filter(exchange("X-Edge-RateLimited"), chain).block();

        verify(chain).filter(any());
    }

    @Test
    void allowsWhenBucketHasTokens() {
        when(chain.filter(any())).thenReturn(Mono.empty());

        filter(new LocalTokenBucket(40, 40, System::nanoTime))
                .filter(exchange(), chain).block();

        verify(chain).filter(any());
    }

    @Test
    void rejectsWith429WhenBucketEmpty() {
        LocalTokenBucket bucket = new LocalTokenBucket(1, 1, System::nanoTime);
        EdgeRateLimitBackstopFilter f = filter(bucket);
        when(chain.filter(any())).thenReturn(Mono.empty());

        f.filter(exchange(), chain).block();   // 消耗唯一 token

        MockServerWebExchange exchange = exchange();
        f.filter(exchange, chain).block();

        verify(chain).filter(any());   // 第一次放行
        assertThat(exchange.getResponse().getStatusCode().value()).isEqualTo(429);
        assertThat(exchange.getResponse().getHeaders().getFirst("X-RateLimit-Remaining")).isEqualTo("0");
        MockServerHttpResponse response = exchange.getResponse();
        assertThat(response.getBodyAsString().block()).contains("\"code\":429");
    }

    @Test
    void burstBelowRateConstructsAndWorks() {
        // 旧 SCG RedisRateLimiter 的 burst>=rate 硬断言随本地化移除：40/20 合法且可放行
        ScgRateLimitProperties props = new ScgRateLimitProperties();
        props.setReplenishRate(40);
        props.setBurstCapacity(20);
        when(chain.filter(any())).thenReturn(Mono.empty());

        new EdgeRateLimitBackstopFilter(props).filter(exchange(), chain).block();

        verify(chain).filter(any());
    }
}
