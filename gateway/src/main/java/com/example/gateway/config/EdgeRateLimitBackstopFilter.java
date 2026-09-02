package com.example.gateway.config;

import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.nio.charset.StandardCharsets;

/**
 * 全局兜底限流（Task 12 本地化版，替代 Redis EVAL 判定）：
 *
 * 1. 带 X-Edge-RateLimited 头的请求 = 已被 nginx 边缘层按 IP 限过 → 直接放行，
 *    正常链路不再被限第二遍；
 * 2. 无该头的请求 = 绕过 nginx 直连 8080 的旁路流量 → 执行本地内存令牌桶
 *    （LocalTokenBucket，rate/burst 来自 scg.rate-limit 配置，默认 40/40，
 *    容量态压测经 env 放大 100000/200000）；
 * 3. 本地桶无 I/O、无故障模式，旧版的 Redis fail-open 分支整体删除。
 *
 * 语义边界：单 gateway 实例下本地桶 = 全局桶（本项目 compose 固定单实例，
 * 不可 scale）；多实例部署需换共享计数（如 Redis 配额分配器），见 nginx.conf.template。
 * 用户/业务维度的限流（需跨实例共享计数）仍走 Redis。
 */
@Component
public class EdgeRateLimitBackstopFilter implements GlobalFilter, Ordered {

    static final String EDGE_HEADER = "X-Edge-RateLimited";

    private final LocalTokenBucket bucket;

    public EdgeRateLimitBackstopFilter(ScgRateLimitProperties props) {
        this(new LocalTokenBucket(props.getReplenishRate(), props.getBurstCapacity()));
    }

    EdgeRateLimitBackstopFilter(LocalTokenBucket bucket) {
        this.bucket = bucket;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        if (exchange.getRequest().getHeaders().containsKey(EDGE_HEADER)) {
            return chain.filter(exchange);
        }
        LocalTokenBucket.AcquireResult res = bucket.tryAcquire();
        if (res.allowed()) {
            return chain.filter(exchange);
        }
        return reject(exchange, res.remainingTokens());
    }

    private Mono<Void> reject(ServerWebExchange exchange, long remaining) {
        exchange.getResponse().setStatusCode(HttpStatus.TOO_MANY_REQUESTS);
        exchange.getResponse().getHeaders().setContentType(MediaType.APPLICATION_JSON);
        exchange.getResponse().getHeaders().add("X-RateLimit-Remaining", String.valueOf(remaining));
        byte[] body = "{\"code\":429,\"msg\":\"rate limited\"}".getBytes(StandardCharsets.UTF_8);
        DataBuffer buffer = exchange.getResponse().bufferFactory().wrap(body);
        return exchange.getResponse().writeWith(Mono.just(buffer));
    }

    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE;
    }
}
