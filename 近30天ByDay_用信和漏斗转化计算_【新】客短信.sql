-- 近30天新客短信 T0 漏斗（By Day）
-- 口径：每个短信发送日独立作为一个 cohort，统计当天 T0 转化
-- 日期范围：最近30个已完成自然日（不含今天）
-- Plan：3032~3120，排除 3069/3070/3071/3072/3081

WITH params AS (
    SELECT
        DATE_SUB(CURDATE(), INTERVAL 30 DAY) AS start_date,
        DATE_SUB(CURDATE(), INTERVAL 1 DAY) AS end_date
),

/* ============================================================
   1. 近30天指定Plan的成功短信
   手机号规则：
   - 2026-08-04及以前：phone为明文
   - 2026-08-05开始：phone为加密，需要解密
   ============================================================ */
sms_raw AS (
    SELECT
        DATE(r.send_time) AS send_date,
        CASE
            WHEN DATE(r.send_time) <= '2026-08-04'
            THEN r.phone
            ELSE etl_data_normalize_decrypt_udf(r.phone)
        END AS phone,
        r.send_time
    FROM ug_analysis_dw_prod.ods_mtn_t_message_record_rt r
    CROSS JOIN params p
    WHERE DATE(r.send_time) BETWEEN p.start_date AND p.end_date
      AND r.send_success = 1
      AND r.plan_id BETWEEN 3032 AND 3120
      AND r.plan_id NOT IN (3069, 3070, 3071, 3072, 3081)
),

/* ============================================================
   2. 每天每个手机号只保留第一次成功短信
   ============================================================ */
sms_user AS (
    SELECT
        send_date,
        phone,
        MIN(send_time) AS first_send_time
    FROM sms_raw
    WHERE phone IS NOT NULL
    GROUP BY send_date, phone
),

/* ============================================================
   3. 每个手机号首次进入Customer / 首次OPT_IN
   ============================================================ */
customer_rank AS (
    SELECT
        id AS customer_id,
        phone,
        create_time,
        ROW_NUMBER() OVER (
            PARTITION BY phone
            ORDER BY create_time, id
        ) AS rn
    FROM ug_analysis_dw_prod.ods_mtn_b_customer
),

customer_first AS (
    SELECT
        customer_id,
        phone,
        create_time AS first_optin_time
    FROM customer_rank
    WHERE rn = 1
),

/* ============================================================
   4. 新客短信母群
   短信发送前尚未OPT_IN
   ============================================================ */
new_sms_cohort AS (
    SELECT
        s.send_date,
        s.phone,
        s.first_send_time,
        c.customer_id,
        c.first_optin_time
    FROM sms_user s
    LEFT JOIN customer_first c
        ON s.phone = c.phone
    WHERE c.first_optin_time IS NULL
       OR c.first_optin_time >= s.first_send_time
),

/* ============================================================
   5. T0 OPT_IN
   必须在短信发送之后，并且与短信同一天
   ============================================================ */
optin_detail AS (
    SELECT
        send_date,
        phone,
        first_send_time,
        customer_id,
        first_optin_time
    FROM new_sms_cohort
    WHERE first_optin_time >= first_send_time
      AND DATE(first_optin_time) = send_date
),

/* ============================================================
   6. T0 Apply
   只有T0 OPT_IN用户进入Apply层
   申请发生在OPT_IN之后，并且与短信同一天
   ============================================================ */
apply_detail AS (
    SELECT
        o.send_date,
        o.phone,
        o.first_send_time,
        o.customer_id,
        a.overdraft_id,
        a.create_time AS apply_time,
        a.apply_result
    FROM optin_detail o
    JOIN ug_analysis_dw_prod.ods_mtn_b_credit_apply a
        ON o.customer_id = a.customer_id
       AND a.create_time >= o.first_optin_time
       AND DATE(a.create_time) = o.send_date
),

/* ============================================================
   7. T0 PASS
   只能从上述Apply记录中筛选PASS
   ============================================================ */
pass_detail AS (
    SELECT DISTINCT
        send_date,
        phone,
        first_send_time,
        customer_id,
        overdraft_id
    FROM apply_detail
    WHERE apply_result = 'PASS'
),

/* ============================================================
   8. Eligible / 有效额度
   最新业务口径：
   - overdraft_status = 'ACTIVE'：当前opted_in
   - total_quota_amount > 0：Credit Eligible
   - total_quota_amount = TCL
   ============================================================ */
eligible_detail AS (
    SELECT DISTINCT
        p.send_date,
        p.phone,
        p.first_send_time,
        p.customer_id,
        p.overdraft_id,
        q.total_quota_amount AS tcl
    FROM pass_detail p
    JOIN ug_analysis_dw_prod.ods_mtn_b_customer_quota q
        ON p.overdraft_id = q.overdraft_id
       AND q.overdraft_status = 'ACTIVE'
       AND q.total_quota_amount > 0
),

/* ============================================================
   9. T0 USAGE
   必须：
   - 来自Eligible用户
   - change_type = 'USAGE'
   - 发生在短信发送之后
   - 与短信发送日同一天
   ============================================================ */
usage_detail AS (
    SELECT
        e.send_date,
        e.phone,
        e.customer_id,
        e.overdraft_id,
        f.change_id,
        f.change_time,
        f.change_amount
    FROM eligible_detail e
    JOIN ug_analysis_dw_prod.ods_mtn_b_customer_quota_flow f
        ON e.overdraft_id = f.overdraft_id
       AND f.change_type = 'USAGE'
       AND f.change_time >= e.first_send_time
       AND DATE(f.change_time) = e.send_date
),

/* ============================================================
   10. 分阶段按天汇总，避免事实表Join导致重复放大
   ============================================================ */
sms_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS sms_user_cnt
    FROM new_sms_cohort
    GROUP BY send_date
),

optin_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS optin_cnt
    FROM optin_detail
    GROUP BY send_date
),

apply_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS apply_cnt
    FROM apply_detail
    GROUP BY send_date
),

pass_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS pass_cnt
    FROM pass_detail
    GROUP BY send_date
),

eligible_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS eligible_cnt,
        SUM(tcl) AS total_tcl
    FROM (
        SELECT DISTINCT
            send_date,
            phone,
            customer_id,
            overdraft_id,
            tcl
        FROM eligible_detail
    ) t
    GROUP BY send_date
),

usage_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS usage_user_cnt,
        COUNT(DISTINCT change_id) AS usage_order_cnt,
        SUM(change_amount) AS usage_amount
    FROM usage_detail
    GROUP BY send_date
)

/* ============================================================
   11. 最终按天输出
   ============================================================ */
SELECT
    s.send_date AS `日期`,

    CASE DAYOFWEEK(s.send_date)
        WHEN 1 THEN '周日'
        WHEN 2 THEN '周一'
        WHEN 3 THEN '周二'
        WHEN 4 THEN '周三'
        WHEN 5 THEN '周四'
        WHEN 6 THEN '周五'
        WHEN 7 THEN '周六'
    END AS `星期`,

    s.sms_user_cnt AS `短信新客触达人数`,
    COALESCE(o.optin_cnt, 0) AS `OPT_IN人数`,
    COALESCE(a.apply_cnt, 0) AS `Apply人数`,
    COALESCE(pa.pass_cnt, 0) AS `PASS人数`,
    COALESCE(e.eligible_cnt, 0) AS `Eligible人数`,
    COALESCE(e.total_tcl, 0) AS `TCL总额`,

    COALESCE(u.usage_user_cnt, 0) AS `用信用户数`,
    COALESCE(u.usage_order_cnt, 0) AS `用信笔数`,
    COALESCE(u.usage_amount, 0) AS `用信总金额`,

    ROUND(
        COALESCE(o.optin_cnt, 0) * 1.0
        / NULLIF(s.sms_user_cnt, 0),
        4
    ) AS `OPT_IN率`,

    ROUND(
        COALESCE(a.apply_cnt, 0) * 1.0
        / NULLIF(o.optin_cnt, 0),
        4
    ) AS `Apply转化率`,

    ROUND(
        COALESCE(pa.pass_cnt, 0) * 1.0
        / NULLIF(a.apply_cnt, 0),
        4
    ) AS `PASS通过率`,

    ROUND(
        COALESCE(e.eligible_cnt, 0) * 1.0
        / NULLIF(pa.pass_cnt, 0),
        4
    ) AS `Eligible率`,

    ROUND(
        COALESCE(u.usage_user_cnt, 0) * 1.0
        / NULLIF(e.eligible_cnt, 0),
        4
    ) AS `用信率`

FROM sms_agg s
LEFT JOIN optin_agg o
    ON s.send_date = o.send_date
LEFT JOIN apply_agg a
    ON s.send_date = a.send_date
LEFT JOIN pass_agg pa
    ON s.send_date = pa.send_date
LEFT JOIN eligible_agg e
    ON s.send_date = e.send_date
LEFT JOIN usage_agg u
    ON s.send_date = u.send_date

ORDER BY s.send_date DESC;
