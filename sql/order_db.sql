CREATE TABLE IF NOT EXISTS orders (
  id            BIGINT PRIMARY KEY,
  order_no      VARCHAR(64) NOT NULL UNIQUE,
  user_id       BIGINT NOT NULL,
  product_name  VARCHAR(128) NOT NULL,
  amount        DECIMAL(10,2) NOT NULL,
  status        TINYINT NOT NULL DEFAULT 0 COMMENT '0=已创建 1=已通知(阶段3消费者更新)',
  create_time   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS users (
  id          BIGINT PRIMARY KEY AUTO_INCREMENT,
  username    VARCHAR(64) NOT NULL UNIQUE,
  password    VARCHAR(128) NOT NULL COMMENT 'BCrypt',
  nickname    VARCHAR(64),
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 种子账号：zhangsan，密码 "123456" 的 BCrypt 密文（Spring Security 官方示例值）
-- 若阶段 3 登录失败，按 Task 11 Step 6 的排查路径重新生成密文回填
INSERT INTO users (username, password, nickname) VALUES
('zhangsan', '$2a$10$N.zmdr9k7uOCQb376NoUnuTJ8iAt6Z5EHsM8lE9lBOsl7iKTVEFDa', '张三');
