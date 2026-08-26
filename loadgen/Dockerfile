# 客户端/压测容器：独立 IP 的"用户"，容器间直连 nginx 保留真实源 IP
# （经宿主机发布端口入站会被 Docker SNAT 坍缩为单 IP，不能用于按 IP 限流演示）
# hey：压测工具（-n 并发数 / -c 连接数）；curl：冒烟与一键请求
FROM alpine:3.20
RUN apk add --no-cache hey curl
