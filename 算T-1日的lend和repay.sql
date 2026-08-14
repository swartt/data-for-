SELECT
    DATE(transaction_time) AS `日期`,
    transaction_type,
    COUNT(*) AS `交易笔数`,
    SUM(principal_amount) AS `金额`
FROM ug_analysis_dw_prod.ods_mtn_b_trans_record
WHERE DATE(transaction_time) = '2026-08-11'
GROUP BY
    DATE(transaction_time),
    transaction_type
ORDER BY transaction_type;
