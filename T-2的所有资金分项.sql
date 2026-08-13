SELECT
    -- abcd
    dt AS `日期`,

    -- 1. 用信/放款金额
    SUM(
        CASE
            WHEN transaction_type = 'Overdraft Funding'
            THEN transaction_amount
            ELSE 0
        END
    ) AS `用信金额`,

    -- 2. 本金回款
    SUM(
        CASE
            WHEN transaction_type = 'Overdraft Repayment'
            THEN transaction_amount
            ELSE 0
        END
    ) AS `本金回款金额`,

    -- 3. Access Fee回款
    SUM(
        CASE
            WHEN transaction_type = 'Overdraft Access Fee Repayment'
            THEN transaction_amount
            ELSE 0
        END
    ) AS `服务费回款金额`,

    -- 4. 利息回款
    SUM(
        CASE
            WHEN transaction_type = 'Overdraft Interest Repayment'
            THEN transaction_amount
            ELSE 0
        END
    ) AS `利息回款金额`,

    -- 5. 总回款金额
    SUM(
        CASE
            WHEN transaction_type IN (
                'Overdraft Repayment',
                'Overdraft Access Fee Repayment',
                'Overdraft Interest Repayment'
            )
            THEN transaction_amount
            ELSE 0
        END
    ) AS `总回款金额`,

    -- 6. 净本金投放
    SUM(
        CASE
            WHEN transaction_type = 'Overdraft Funding'
            THEN transaction_amount
            ELSE 0
        END
    )
    -
    SUM(
        CASE
            WHEN transaction_type = 'Overdraft Repayment'
            THEN transaction_amount
            ELSE 0
        END
    ) AS `净本金投放金额`

FROM ug_analysis_dw_prod.dwd_mtn_overdraft_transaction_di

WHERE dt = '2026-08-10'
  AND overdraft_id IS NOT NULL

GROUP BY dt;
