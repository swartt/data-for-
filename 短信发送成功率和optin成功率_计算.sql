--计算每日的新客营销发送量、成功量和成功率（区分特定plan_id)（指定日期和plan_id)
SELECT
    DATE(send_time) AS send_date,

    -- 每日发送用户数（去重手机号）
    COUNT(DISTINCT phone) AS `发送用户数`,

    -- 每日发送成功用户数（去重手机号）
    COUNT(DISTINCT CASE 
        WHEN send_success = 1 
        THEN phone 
    END) AS `发送成功用户数`,

    -- 发送成功率
    ROUND(
        COUNT(DISTINCT CASE 
            WHEN send_success = 1 
            THEN phone 
        END)
        /
        COUNT(DISTINCT phone),
        4
    ) AS `发送成功率`,
   --plan_id
    plan_id

FROM ug_analysis_dw_prod.ods_mtn_t_message_record_rt

where plan_id between 3117 and 3120 and date(send_time) = '2026-08-11'

GROUP BY DATE(send_time),plan_id

ORDER BY send_date,plan_id;


----计算每日的新客营销发送量、成功量和成功率（合并特定plan_id）（指定日期和plan_id)
SELECT
    DATE(send_time) AS send_date,

    -- 每日发送用户数（去重手机号）
    COUNT(DISTINCT phone) AS `发送用户数`,

    -- 每日发送成功用户数（去重手机号）
    COUNT(DISTINCT CASE 
        WHEN send_success = 1 
        THEN phone 
    END) AS `发送成功用户数`,

    -- 发送成功率
    ROUND(
        COUNT(DISTINCT CASE 
            WHEN send_success = 1 
            THEN phone 
        END)
        /
        COUNT(DISTINCT phone),
        4
    ) AS `发送成功率`

FROM ug_analysis_dw_prod.ods_mtn_t_message_record_rt

where plan_id in (3008,3009) and date(send_time) = '2026-07-01'

GROUP BY DATE(send_time)

ORDER BY send_date;




--计算optin 转化率 （不区分plan_id,算当日总和）

WITH send_user AS
(
    -- 1. 获取指定日期、指定plan成功发送用户
    -- message_record中的phone先解密
    SELECT DISTINCT
        etl_data_normalize_decrypt_udf(phone) AS decrypt_phone,
        DATE(send_time) AS send_date
    FROM ug_analysis_dw_prod.ods_mtn_t_message_record_rt
      WHERE plan_id between 3117 and 3120
      and send_success = 1
      AND DATE(send_time) = '2026-08-11'
),

customer_first AS
(
    -- 2. 获取每个手机号首次进入customer表的日期
    SELECT
        phone,
        MIN(DATE(create_time)) AS first_create_date
    FROM ug_analysis_dw_prod.ods_mtn_b_customer
    GROUP BY phone
)

SELECT
    s.send_date,

    -- 成功发送用户数
    COUNT(DISTINCT s.decrypt_phone) AS `成功发送用户数`,

    -- T0当天首次落到customer的用户数
    COUNT(DISTINCT CASE
        WHEN c.first_create_date = s.send_date
        THEN s.decrypt_phone
    END) AS `OPT_IN_T0转化用户数`,

    -- T0转化率
    CONCAT(
        ROUND(
            COUNT(DISTINCT CASE
                WHEN c.first_create_date = s.send_date
                THEN s.decrypt_phone
            END)
            /
            NULLIF(COUNT(DISTINCT s.decrypt_phone), 0)
            * 100,
            2
        ),
        '%'
    ) AS `OPT_IN_T0转化率`

FROM send_user s

LEFT JOIN customer_first c
    ON s.decrypt_phone = c.phone

GROUP BY s.send_date

ORDER BY s.send_date;



-- 计算各 plan_id 的 OPT-IN T0 转化率（区分plan_id）

WITH send_user AS
(
    -- 1. 获取指定日期、指定 plan 成功发送用户
    -- message_record 中的 phone 先解密
    SELECT DISTINCT
        plan_id,
        etl_data_normalize_decrypt_udf(phone) AS decrypt_phone,
        DATE(send_time) AS send_date
    FROM ug_analysis_dw_prod.ods_mtn_t_message_record_rt
    WHERE plan_id BETWEEN 3117 AND 3120
      AND send_success = 1
      AND DATE(send_time) = '2026-08-11'
),

customer_first AS
(
    -- 2. 获取每个手机号首次进入 customer 表的日期
    SELECT
        phone,
        MIN(DATE(create_time)) AS first_create_date
    FROM ug_analysis_dw_prod.ods_mtn_b_customer
    GROUP BY phone
)

SELECT
    s.send_date,
    s.plan_id,

    -- 成功发送用户数
    COUNT(DISTINCT s.decrypt_phone) AS `成功发送用户数`,

    -- T0 当天首次落到 customer 的用户数
    COUNT(DISTINCT CASE
        WHEN c.first_create_date = s.send_date
        THEN s.decrypt_phone
    END) AS `OPT_IN_T0转化用户数`,

    -- T0 转化率
    CONCAT(
        ROUND(
            COUNT(DISTINCT CASE
                WHEN c.first_create_date = s.send_date
                THEN s.decrypt_phone
            END)
            /
            NULLIF(COUNT(DISTINCT s.decrypt_phone), 0)
            * 100,
            2
        ),
        '%'
    ) AS `OPT_IN_T0转化率`

FROM send_user s

LEFT JOIN customer_first c
    ON s.decrypt_phone = c.phone

GROUP BY
    s.send_date,
    s.plan_id

ORDER BY
    s.send_date,
    s.plan_id;