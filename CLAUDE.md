# 工作筆記

## PressPlay 合購盛典 自動化 SQL（ICS promote_sql）

合購盛典（全站長期合購，`pbs_id = A8D4E87C175CCBF3F5F0A8D7E86307C4`）的課程池由一支
自動化 SQL 決定，設定在 ICS 後台。這支 SQL 有幾個踩過的雷，改之前先看這裡。

### ⚠️ 不要再加 JOIN

這支 SQL 的 JOIN 鏈裡有一個 `RIGHT JOIN`（掛 `project_reward` 子查詢那段）。
MySQL 處理 `RIGHT JOIN` 時會把左邊那串表先包成一組再反轉，之後再接新的 JOIN 去
引用 `p.project_id`，結合順序會跑掉，常見錯誤是
`Unknown column 'p.project_id' in 'on clause'`，在 ICS 後台則是直接 server error。

實際踩過的兩次失敗：

- 把熱度統計寫成 `LEFT JOIN (SELECT ... GROUP BY project_id) AS pop` 掛在 RIGHT JOIN
  後面 → 爆。
- 用 `WITH ... AS (...)` 改寫成 CTE → 爆。**ICS 的 promote_sql 只吃 `SELECT` 開頭**，
  `WITH` 開頭會被驗證器擋掉，根本沒送到資料庫。

### ✅ 正確的擴充方式

| 要做的事 | 用這個 | 不要用 |
|---|---|---|
| 加篩選條件 | `EXISTS (SELECT 1 ...)` | `JOIN` |
| 加排序 | `ORDER BY (SELECT ... )` 相關子查詢 | `JOIN` 一張 derived table |
| 開頭 | `SELECT` | `WITH` |

相關子查詢是獨立求值的，不參與 JOIN，所以完全繞開 `RIGHT JOIN` 的問題。

### 分類拆分

課程分類是兩層式：

- `project_type_relationship`：`project_id` ↔ `type_id`，**多對多**（一堂課可掛多個分類）
- `project_type`：`type_id`、`type_name`、`parent_type_id`
- 取大分類要用 `COALESCE(父分類名, 自己的名稱)`，因為有些課直接掛在大分類上
- **特例**：「AI」是掛在職場技能底下的子分類（`type_id = 3D9A163A138B84875CF37818CFDB2CAB`）。
  若要讓 AI 獨立成一區，職場技能那支要另外 `NOT EXISTS` 排除它，否則同一批課會兩邊都出現。

分類篩選寫法（換分類只改字串）：

```sql
AND EXISTS (
    SELECT 1
    FROM project_type_relationship ptr
    JOIN project_type pt ON pt.type_id = ptr.type_id
    LEFT JOIN project_type ptp ON ptp.type_id = pt.parent_type_id
    WHERE ptr.project_id = p.project_id
      AND COALESCE(ptp.type_name, pt.type_name) = "職場技能"
)
```

用 `EXISTS` 不用 `JOIN` 還有第二個理由：多對多 JOIN 會讓一堂掛多分類的課變成多列，
池子筆數莫名膨脹。`EXISTS` 只做存在性判斷，列數跟原本一致。

排序＋取前 N（放在整段最後面，`SELECT DISTINCT` 要改回 `SELECT`）：

```sql
GROUP BY p.project_id
ORDER BY (SELECT COUNT(DISTINCT ps.member_id) FROM project_subscribe ps
          WHERE ps.project_id = p.project_id AND ps.subscribe_status = 'active'
            AND ps.subscribe_date >= DATE_SUB(NOW(), INTERVAL 90 DAY)) DESC
LIMIT 20
```

### 池子現況（2026-09 實測）

- 池子總課程數約 830 堂
- 分類分布：職場技能 348、生活品味 178、健康健身 136、藝文娛樂 105、投資理財 93、
  烘焙料理 59、行銷 59、語言學習 56（加總 1,034，平均一堂課掛 1.25 個分類，重疊輕微）
- **ICS 合購課程數上限是 15 堂**，要更多得請拜倫開。策展頁顯示不受此限。

### 除錯方式

ICS 只回 server error、沒有細節。每次只改一樣東西，從已知可跑的版本出發，
逐一加 `LIMIT` / `GROUP BY` / `ORDER BY`，就能定位是哪個語法被擋。

---

## 資料查詢環境（重要）

- 站上訂單資料（`project_subscribe`、`project_subscribe_order` 等）在 **Metabase / MySQL**，
  不在 BigQuery。語法是 MySQL（`IF()`、`NOW()`、`DATE_FORMAT()`）。
- **BigQuery 只有 GA4 資料**（`analytics_313864326`，含已合併 WEB/APP 的
  `all_channel_events_new`）。把訂單類 SQL 貼到 BigQuery 會報語法錯。
- 訂單類 SQL 的標準條件：`ps.subscribe_date IS NOT NULL`、`ps.partner_id IS NULL`（排浦惠）、
  `ps.donate_price > 0`、`ps.region_id = 'TW'`、`pso.order_price > 0`、`pso.pay_result = 'y'`。
  營收 ＝ `order_price − order_fee_amt − order_discount_amt − order_coupon_amt − order_points_amt`。
  月份要看 `pso.order_time`，不是 `ps.subscribe_date`。
- 單次購 ＝ `ps.pay_period = 'forever'`。
