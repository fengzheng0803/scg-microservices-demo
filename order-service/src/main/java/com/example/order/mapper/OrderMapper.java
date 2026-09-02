package com.example.order.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.example.order.entity.Order;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface OrderMapper extends BaseMapper<Order> {

    /** 慢库模拟：单行查询强制 SLEEP 50ms（延迟注入在 MySQL 侧——占连接、不烧 CPU，形态与真实慢查询一致） */
    @Select("SELECT id, order_no, user_id, product_name, amount, status, create_time " +
            "FROM orders WHERE id = #{id} AND SLEEP(0.05) = 0")
    Order selectByIdWithDelay(@Param("id") Long id);
}
