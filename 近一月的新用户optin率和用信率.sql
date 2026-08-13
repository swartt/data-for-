WITH sms_raw AS (
    /* ========================================================
       1. 近1个月指定Plan的成功短信
       日期：2026-07-11 ~ 2026-08-11

       手机号规则：
       - 8/4及以前：明文手机号
       - 8/5开始：加密手机号，需要解密
       ======================================================== */
    SELECT
        DATE(r.send_time) AS send_date,

        CASE
            WHEN DATE(r.send_time) <= '2026-08-04'
            THEN r.phone
            ELSE etl_data_normalize_decrypt_udf(r.phone)
        END AS phone,

        r.send_time

    FROM ug_analysis_dw_prod.ods_mtn_t_message_record_rt r

    WHERE DATE(r.send_time) BETWEEN '2026-07-11' AND '2026-08-11'
      AND r.send_success = 1
      AND r.plan_id BETWEEN 3032 AND 3120
      AND r.plan_id NOT IN (3069, 3070, 3071, 3081)
),

sms_user AS (
    /* ========================================================
       2. 每天每个手机号只保留第一次成功短信
       ======================================================== */
    SELECT
        send_date,
        phone,
        MIN(send_time) AS first_send_time

    FROM sms_raw

    WHERE phone IS NOT NULL

    GROUP BY
        send_date,
        phone
),

customer_rank AS (
    /* ========================================================
       3. 每个手机号首次进入Customer / OPT_IN的时间
       ======================================================== */
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

new_customer_cohort AS (
    /* ========================================================
       4. 新客短信母群

       新客：
       短信发送前尚未完成OPT_IN
       ======================================================== */
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

optin_detail AS (
    /* ========================================================
       5. T0 OPT_IN

       必须：
       - 属于当天短信新客
       - OPT_IN发生在短信发送之后
       - OPT_IN与短信同一天
       ======================================================== */
    SELECT
        send_date,
        phone,
        first_send_time,
        customer_id,
        first_optin_time

    FROM new_customer_cohort

    WHERE first_optin_time >= first_send_time
      AND DATE(first_optin_time) = send_date
),

eligible_customer AS (
    /* ========================================================
       6. Credit Eligible
       total_quota_amount > 0
       total_quota_amount = TCL
       ======================================================== */
    SELECT DISTINCT
        customer_id,
        overdraft_id,
        total_quota_amount

    FROM ug_analysis_dw_prod.ods_mtn_b_customer_quota

    WHERE total_quota_amount > 0
),

usage_detail AS (
    /* ========================================================
       7. T0用信

       必须：
       - 当天完成OPT_IN的新客
       - 已Credit Eligible
       - change_type = 'USAGE'
       - USAGE发生在短信发送之后
       - USAGE发生在短信当天
       ======================================================== */
    SELECT
        o.send_date,
        o.phone,
        o.customer_id,

        f.change_id,
        f.change_time,
        f.change_amount

    FROM optin_detail o

    JOIN eligible_customer q
        ON o.customer_id = q.customer_id

    JOIN ug_analysis_dw_prod.ods_mtn_b_customer_quota_flow f
        ON q.overdraft_id = f.overdraft_id
       AND f.change_type = 'USAGE'
       AND f.change_time >= o.first_send_time
       AND DATE(f.change_time) = o.send_date
),

sms_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS sms_new_customer_cnt

    FROM new_customer_cohort

    GROUP BY send_date
),

optin_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS optin_t0_cnt

    FROM optin_detail

    GROUP BY send_date
),

usage_agg AS (
    SELECT
        send_date,
        COUNT(DISTINCT phone) AS usage_t0_user_cnt

    FROM usage_detail

    GROUP BY send_date
)

SELECT
    s.send_date AS `日期`,

    /* 星期 */
    CASE DAYOFWEEK(s.send_date)
        WHEN 1 THEN '周日'
        WHEN 2 THEN '周一'
        WHEN 3 THEN '周二'
        WHEN 4 THEN '周三'
        WHEN 5 THEN '周四'
        WHEN 6 THEN '周五'
        WHEN 7 THEN '周六'
    END AS `星期`,

    /* 新客短信触达 */
    s.sms_new_customer_cnt AS `新客短信触达人数`,

    /* T0 OPT_IN */
    COALESCE(o.optin_t0_cnt, 0) AS `T0_OPT_IN人数`,

    ROUND(
        COALESCE(o.optin_t0_cnt, 0) * 1.0
        /
        NULLIF(s.sms_new_customer_cnt, 0),
        4
    ) AS `T0_OPT_IN率`,

    /* T0用信 */
    COALESCE(u.usage_t0_user_cnt, 0) AS `T0用信用户数`,

    ROUND(
        COALESCE(u.usage_t0_user_cnt, 0) * 1.0
        /
        NULLIF(o.optin_t0_cnt, 0),
        4
    ) AS `T0用信用户率`

FROM sms_agg s

LEFT JOIN optin_agg o
    ON s.send_date = o.send_date

LEFT JOIN usage_agg u
    ON s.send_date = u.send_date

ORDER BY s.send_date;