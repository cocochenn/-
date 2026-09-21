-- =============================================================
-- PPA 2026 年度回顧｜資料撈取
-- 產出對象：單一會員（先驗證欄位撈得出來、數字合理，再擴大全站）
--
-- 資料分兩邊：
--   A. MySQL      → 訂單、會員階級、點數、購課記錄
--   B. BigQuery   → GA4 行為：觀看、時段、內容數、老師與分類接觸
--
-- 執行方式：用 /data skill。BigQuery 走 bq query --use_legacy_sql=false；
-- MySQL 需 SSH tunnel + pymysql。連線資訊在 memory 的
-- mysql_connection.md / bigquery_connections.md，欄位以
-- pressplay_db_schema_notion.md 為準——下方表名欄位是推測，請對照後修正。
-- =============================================================


-- #############################################################
-- A · MySQL：訂單與會員階級
-- #############################################################

-- ---------- 參數 ----------
SET @member_id    = 'PUT_MEMBER_ID_HERE';
SET @year_start   = '2026-01-01 00:00:00';
SET @year_end     = '2027-01-01 00:00:00';   -- 半開區間
SET @prev_start   = '2025-01-01 00:00:00';
SET @prev_end     = '2026-01-01 00:00:00';
SET @period_start = '2026-01-28 00:00:00';   -- ⚠ 效期起算，待確認
SET @period_end   = '2027-05-01 00:00:00';   -- ⚠ 效期結束，待確認


-- -------------------------------------------------------------
-- A1 · 會員階級與效期
-- 用於：卡 01 稱號、卡 03 你在哪個階級、卡 09 升級／保級門檻
-- 先看原始多筆，確認「當前階級」該怎麼取。
-- ⚠ 抽樣中出現同一 member_id 在同一秒有鉑金與白銀兩筆，
--   這張表若是異動歷程，取當前階級需要明確規則。
-- ⚠ effective_from 大量集中在 2026-01-28 11:07，是制度上線批次灌檔，
--   不是真實升級日，不可用於「你在 X 月升級」類文案。
-- -------------------------------------------------------------
SELECT member_id, tier_name, effective_from, effective_to
FROM member_tiers
WHERE member_id = @member_id
ORDER BY effective_from DESC, tier_name DESC;


-- -------------------------------------------------------------
-- A2 · 消費：今年、去年、效期內累積、終身累積
-- 用於：卡 02 猜金額、卡 04 階級內比較、卡 09 門檻進度條
-- ⚠ 確認 status 值，並確認是否排除退款、公關單、0 元專案
-- -------------------------------------------------------------
SELECT
    SUM(CASE WHEN paid_at >= @year_start   AND paid_at < @year_end
             THEN total_amount ELSE 0 END)                 AS spend_2026,
    SUM(CASE WHEN paid_at >= @prev_start   AND paid_at < @prev_end
             THEN total_amount ELSE 0 END)                 AS spend_2025,
    SUM(CASE WHEN paid_at >= @period_start AND paid_at < @period_end
             THEN total_amount ELSE 0 END)                 AS spend_in_period,
    SUM(total_amount)                                      AS spend_lifetime,
    COUNT(DISTINCT CASE WHEN paid_at >= @year_start AND paid_at < @year_end
                        THEN order_id END)                 AS orders_2026
FROM orders
WHERE member_id = @member_id
  AND status = 'paid';


-- -------------------------------------------------------------
-- A3 · 省下的金額（折價券 + 點數）
-- 用於：卡 05 你省下的
-- 學習軌跡頁已有「聰明消費省的金額」，優先沿用該頁既有算法；
-- 這段是備援，且該頁若是 lifetime 值，年度回顧要改成年度區間。
-- -------------------------------------------------------------
SELECT
    SUM(discount_amount)                     AS coupon_saved,
    SUM(points_used)                         AS points_saved,
    SUM(discount_amount + points_used)       AS total_saved
FROM orders
WHERE member_id = @member_id
  AND status = 'paid'
  AND paid_at >= @year_start AND paid_at < @year_end;


-- -------------------------------------------------------------
-- A4 · 購課數與已購課程清單
-- 用於：卡 01 稱號、卡 12 老師的其他課（排除已購）
-- -------------------------------------------------------------
SELECT COUNT(DISTINCT oi.course_id) AS courses_bought_2026
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.member_id = @member_id
  AND o.status = 'paid'
  AND o.paid_at >= @year_start AND o.paid_at < @year_end;

-- 已購清單（含歷年，供排除用）
SELECT DISTINCT oi.course_id
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.member_id = @member_id AND o.status = 'paid';


-- -------------------------------------------------------------
-- A5 · 同班同學與後續選課
-- 用於：卡 10 同班同學
-- 全站掃描，資料量大，建議先在測試環境跑。
-- -------------------------------------------------------------

-- A5a 同班人數
SELECT COUNT(DISTINCT peer.member_id) AS classmates
FROM orders o
JOIN order_items oi  ON oi.order_id = o.order_id
JOIN order_items poi ON poi.course_id = oi.course_id
JOIN orders peer     ON peer.order_id = poi.order_id
WHERE o.member_id = @member_id
  AND o.status = 'paid' AND peer.status = 'paid'
  AND peer.member_id <> @member_id;

-- A5b 同班的人還買了哪些這位會員沒買的課（協同過濾第一版）
WITH my_courses AS (
    SELECT DISTINCT oi.course_id
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.member_id = @member_id AND o.status = 'paid'
),
classmates AS (
    SELECT DISTINCT o.member_id
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'paid'
      AND oi.course_id IN (SELECT course_id FROM my_courses)
      AND o.member_id <> @member_id
)
SELECT
    oi.course_id,
    COUNT(DISTINCT o.member_id) AS peers_bought
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'paid'
  AND o.member_id IN (SELECT member_id FROM classmates)
  AND oi.course_id NOT IN (SELECT course_id FROM my_courses)
GROUP BY oi.course_id
ORDER BY peers_bought DESC
LIMIT 5;


-- -------------------------------------------------------------
-- A6 · 全站：各階級人數與 ARPU（跑一次即可）
-- 用於：卡 03 階級分佈、卡 04 階級內比較
-- ⚠ 需依現行門檻 7,500 / 25,000 / 65,000 重算。
--   現有的分級機制表用的是舊級距 5,000 / 20,000 / 40,000，白銀以上會高估。
-- -------------------------------------------------------------
SELECT
    t.tier_name,
    COUNT(DISTINCT t.member_id)      AS members,
    ROUND(AVG(s.spend_2026), 0)      AS arpu_2026,
    ROUND(AVG(s.spend_lifetime), 0)  AS arpu_lifetime
FROM (
    SELECT member_id, tier_name
    FROM member_tiers
    WHERE effective_to IS NULL          -- ⚠ 依 A1 確認的規則調整
) t
LEFT JOIN (
    SELECT
        member_id,
        SUM(CASE WHEN paid_at >= @year_start AND paid_at < @year_end
                 THEN total_amount ELSE 0 END) AS spend_2026,
        SUM(total_amount)                      AS spend_lifetime
    FROM orders
    WHERE status = 'paid'
    GROUP BY member_id
) s ON s.member_id = t.member_id
GROUP BY t.tier_name;


-- #############################################################
-- B · BigQuery：GA4 學習行為
--
-- 優先用整合表 pressplay-platform-203406.analytics_313864326.all_channel_events_new
-- （Web + App 已攤平、event_params 已展開，用 event_date 過濾，不必碰 raw events_*）
--
-- ⚠ 以下事件名與參數名為推測，請對照 memory 的 ga_events.md 修正：
--     事件：page_view / video_progress / content_view
--     參數：content_id, course_id, creator_id, category, member_id
-- ⚠ 確認 GA4 的 member_id 與 MySQL 的 member_id 是同一組值，
--   否則兩邊資料接不起來——這是整個年度回顧最關鍵的前提。
-- #############################################################

-- -------------------------------------------------------------
-- B1 · 學習量：內容數、學習天數（今年 vs 去年）
-- 用於：卡 01 稱號、卡 06 你今年看了多少、同比文案
-- 注意：學習軌跡頁目前顯示 lifetime 累積，年度回顧要年度值。
-- -------------------------------------------------------------
SELECT
    FORMAT_DATE('%Y', PARSE_DATE('%Y%m%d', event_date))  AS yr,
    COUNT(DISTINCT content_id)                            AS contents_viewed,
    COUNT(DISTINCT event_date)                            AS active_days
FROM `pressplay-platform-203406.analytics_313864326.all_channel_events_new`
WHERE member_id = 'PUT_MEMBER_ID_HERE'
  AND event_date BETWEEN '20250101' AND '20261231'
  AND event_name IN ('content_view', 'video_progress')
GROUP BY yr
ORDER BY yr;


-- -------------------------------------------------------------
-- B2 · 學習時段分佈（小時級）
-- 用於：卡 07 學習人格
-- 現有欄位只有粗分類（白天／晚上），要做分佈圖得撈到小時。
-- ⚠ GA4 的 event_timestamp 是 UTC 微秒，一定要轉 Asia/Taipei，
--   否則時段整個偏 8 小時，「半夜苦讀派」會變成「下午派」。
-- -------------------------------------------------------------
SELECT
    EXTRACT(HOUR FROM DATETIME(TIMESTAMP_MICROS(event_timestamp), 'Asia/Taipei')) AS hour_of_day,
    COUNT(*)                   AS events,
    COUNT(DISTINCT event_date) AS days
FROM `pressplay-platform-203406.analytics_313864326.all_channel_events_new`
WHERE member_id = 'PUT_MEMBER_ID_HERE'
  AND event_date BETWEEN '20260101' AND '20261231'
  AND event_name IN ('content_view', 'video_progress')
GROUP BY hour_of_day
ORDER BY hour_of_day;


-- -------------------------------------------------------------
-- B3 · 月分佈
-- 用於：卡 06 的月曲線
-- -------------------------------------------------------------
SELECT
    FORMAT_DATE('%Y-%m', PARSE_DATE('%Y%m%d', event_date)) AS ym,
    COUNT(DISTINCT content_id)                              AS contents_viewed
FROM `pressplay-platform-203406.analytics_313864326.all_channel_events_new`
WHERE member_id = 'PUT_MEMBER_ID_HERE'
  AND event_date BETWEEN '20260101' AND '20261231'
  AND event_name IN ('content_view', 'video_progress')
GROUP BY ym
ORDER BY ym;


-- -------------------------------------------------------------
-- B4 · 領域分佈
-- 用於：卡 12 猜主戰場、卡 13 領域圖鑑
-- -------------------------------------------------------------
SELECT
    category,
    COUNT(DISTINCT course_id)  AS courses_touched,
    COUNT(DISTINCT content_id) AS contents_viewed
FROM `pressplay-platform-203406.analytics_313864326.all_channel_events_new`
WHERE member_id = 'PUT_MEMBER_ID_HERE'
  AND event_date BETWEEN '20260101' AND '20261231'
  AND event_name IN ('content_view', 'video_progress')
  AND category IS NOT NULL
GROUP BY category
ORDER BY contents_viewed DESC;


-- -------------------------------------------------------------
-- B5 · 年度老師
-- 用於：卡 11 你的老師
-- -------------------------------------------------------------
SELECT
    creator_id,
    COUNT(DISTINCT content_id) AS contents_viewed,
    COUNT(DISTINCT course_id)  AS courses_touched
FROM `pressplay-platform-203406.analytics_313864326.all_channel_events_new`
WHERE member_id = 'PUT_MEMBER_ID_HERE'
  AND event_date BETWEEN '20260101' AND '20261231'
  AND event_name IN ('content_view', 'video_progress')
  AND creator_id IS NOT NULL
GROUP BY creator_id
ORDER BY contents_viewed DESC
LIMIT 1;


-- -------------------------------------------------------------
-- B6 · 在該老師學生中的排名
-- 用於：卡 11「你排前 X%」
-- -------------------------------------------------------------
WITH per_student AS (
    SELECT
        member_id,
        COUNT(DISTINCT content_id) AS contents_viewed
    FROM `pressplay-platform-203406.analytics_313864326.all_channel_events_new`
    WHERE creator_id = 'PUT_CREATOR_ID_HERE'
      AND event_date BETWEEN '20260101' AND '20261231'
      AND event_name IN ('content_view', 'video_progress')
    GROUP BY member_id
),
ranked AS (
    SELECT
        member_id,
        contents_viewed,
        RANK()         OVER (ORDER BY contents_viewed DESC) AS rnk,
        PERCENT_RANK() OVER (ORDER BY contents_viewed)      AS pct,
        COUNT(*)       OVER ()                              AS total_students
    FROM per_student
)
SELECT
    member_id, contents_viewed, rnk, total_students,
    ROUND((1 - pct) * 100, 1) AS top_percent
FROM ranked
WHERE member_id = 'PUT_MEMBER_ID_HERE';


-- -------------------------------------------------------------
-- B7 · 全站內容數的百分位分佈（青銅以上）
-- 用於：卡 08 賭一把排名
-- 這張卡沒有這段就寫不出文案。
-- ⚠ 需要先有一份青銅以上的 member_id 清單（從 MySQL A6 匯出），
--   或在 BQ 建一張暫存表 join。
-- -------------------------------------------------------------
WITH per_member AS (
    SELECT
        member_id,
        COUNT(DISTINCT content_id) AS contents_viewed
    FROM `pressplay-platform-203406.analytics_313864326.all_channel_events_new`
    WHERE event_date BETWEEN '20260101' AND '20261231'
      AND event_name IN ('content_view', 'video_progress')
      AND member_id IN (SELECT member_id FROM `PUT_TIER_TABLE_HERE`)  -- 青銅以上
    GROUP BY member_id
),
d AS (
    SELECT
        member_id,
        contents_viewed,
        PERCENT_RANK() OVER (ORDER BY contents_viewed)      AS pct,
        RANK()         OVER (ORDER BY contents_viewed DESC) AS rnk,
        COUNT(*)       OVER ()                              AS population
    FROM per_member
)
SELECT
    MIN(contents_viewed)  AS min_contents,
    MAX(contents_viewed)  AS max_contents,
    ROUND(AVG(contents_viewed), 1) AS avg_contents,
    MAX(IF(pct <= 0.50, contents_viewed, NULL)) AS p50,
    MAX(IF(pct <= 0.70, contents_viewed, NULL)) AS p70,
    MAX(IF(pct <= 0.90, contents_viewed, NULL)) AS p90,
    MAX(IF(pct <= 0.95, contents_viewed, NULL)) AS p95,
    MAX(IF(pct <= 0.99, contents_viewed, NULL)) AS p99,
    MAX(population)       AS population
FROM d;

-- 這位會員在上述母體的百分位與名次（卡 08 揭曉用）
-- 把上面的 d 換成同一段 CTE 後：
--   SELECT member_id, contents_viewed, ROUND(pct * 100, 1) AS beats_percent, rnk, population
--   FROM d WHERE member_id = 'PUT_MEMBER_ID_HERE';


-- =============================================================
-- 跑完之後要回答的四件事
--   1. GA4 的 member_id 與 MySQL 的 member_id 是否為同一組值？
--      接不起來的話，整個年度回顧只能做單邊資料。
--   2. A1 能否明確取出單一「當前階級」？
--   3. B2 轉時區後，時段分佈看起來合理嗎？
--   4. B7 的 p95 / p99 落在多少？若 p95 遠高於中位數，
--      「再 X 篇就進前 5%」對中段會員不是可達目標，
--      門檻文案就要改用階級升級（卡 09 已經是這個設計）。
-- =============================================================
