package com.example.order.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/** 订单实体，对应 orders 表 */
@Data
@TableName("orders")
public class Order {

    /** 雪花 ID（MyBatis-Plus ASSIGN_ID） */
    @TableId(type = IdType.ASSIGN_ID)
    private Long id;

    private String orderNo;

    private Long userId;

    private String productName;

    private BigDecimal amount;

    /** 0=已创建 1=已通知 */
    private Integer status;

    private LocalDateTime createTime;
}
