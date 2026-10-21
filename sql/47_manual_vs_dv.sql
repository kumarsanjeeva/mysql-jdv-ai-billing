-- Builds order 77 by hand from the base tables (JSON_OBJECT / JSON_ARRAYAGG), reads the same order
-- from order_dv, and compares them with the view's _metadata removed. Read-only; run as the admin
-- (the agent has no grants on the base tables). Field names and nesting follow sql/02_duality_views.sql.
USE __MYSQL_DB__;

SELECT '== 0. the order exists' AS step;
SELECT id, business_id, order_status, total FROM orders WHERE id = 77;

-- 1. hand-built document (items and payments ordered by id; the view definition has no ORDER BY)
SET @manual = (
  SELECT JSON_OBJECT(
    '_id', o.id,
    'business_id', o.business_id,
    'request_id', o.request_id,
    'order_status', o.order_status,
    'delivery_address', o.delivery_address,
    'delivery_at', o.delivery_at,
    'subtotal', o.subtotal,
    'discount_type', o.discount_type,
    'discount_value', o.discount_value,
    'gst_value', o.gst_value,
    'total', o.total,
    'cancellation_reason', o.cancellation_reason,
    'created_at', o.created_at,
    'outlet', (SELECT JSON_OBJECT('id', ou.id, 'name', ou.name)
               FROM outlets ou WHERE ou.id = o.outlet_id),
    'customer', (SELECT JSON_OBJECT('id', c.id, 'name', c.name, 'phone', c.phone)
                 FROM customers c WHERE c.id = o.customer_id),
    'items', (SELECT JSON_ARRAYAGG(JSON_OBJECT(
                'id', i.id, 'name', i.name, 'flavor', i.flavor, 'size', i.size, 'unit', i.unit,
                'qty', i.qty, 'price', i.price, 'gst_rate', i.gst_rate,
                'is_gst_inclusive', i.is_gst_inclusive, 'gst_applicable', i.gst_applicable,
                'discount_exempt', i.discount_exempt, 'gst_value', i.gst_value,
                'discount_value', i.discount_value, 'notes', i.notes,
                'product', (SELECT JSON_OBJECT('id', p.id, 'name', p.name)
                            FROM products p WHERE p.id = i.product_id),
                'product_variant_id', i.product_variant_id))
              FROM (SELECT * FROM order_items WHERE order_id = 77 ORDER BY id) i),
    'payments', (SELECT JSON_ARRAYAGG(JSON_OBJECT(
                'id', pm.id, 'business_id', pm.business_id, 'request_id', pm.request_id,
                'payment_type', pm.payment_type, 'method', pm.method,
                'amount', pm.amount, 'paid_at', pm.paid_at))
              FROM (SELECT * FROM payments WHERE order_id = 77 ORDER BY id) pm)
  )
  FROM orders o WHERE o.id = 77
);

-- 2. the same order from the duality view
SET @view = (SELECT data FROM order_dv WHERE JSON_VALUE(data, '$._id') = 77);

SELECT '== 1. hand-built (JSON_OBJECT / JSON_ARRAYAGG)' AS step;
SELECT JSON_PRETTY(@manual) AS manual_json;

SELECT '== 2. order_dv (as returned, with _metadata)' AS step;
SELECT JSON_PRETTY(@view) AS view_json;

-- 3. comparison with _metadata removed
SET @view_no_meta = JSON_REMOVE(@view, '$._metadata');
SELECT '== 3. comparison' AS step;
SELECT
  (@manual = @view_no_meta)                              AS json_values_equal,
  (CAST(@manual AS CHAR) = CAST(@view_no_meta AS CHAR))  AS text_equal,
  JSON_LENGTH(@manual)                                   AS manual_top_keys,
  JSON_LENGTH(@view_no_meta)                             AS view_top_keys_without_metadata,
  JSON_LENGTH(@view)                                     AS view_top_keys_with_metadata;
SELECT '== 3b. top-level keys only the view returns' AS step;
SELECT JSON_KEYS(@view) AS view_keys, JSON_KEYS(@manual) AS manual_keys;
SELECT JSON_PRETTY(JSON_EXTRACT(@view, '$._metadata')) AS view_metadata_only;
-- 4. where do they differ? compare each top-level key, and the JSON type each side holds
SELECT '== 4. per-key comparison (1 = equal)' AS step;
SELECT j.k AS top_level_key,
       (JSON_EXTRACT(@manual, CONCAT('$."', j.k, '"')) = JSON_EXTRACT(@view_no_meta, CONCAT('$."', j.k, '"'))) AS equal_as_json,
       (CAST(JSON_EXTRACT(@manual, CONCAT('$."', j.k, '"')) AS CHAR) = CAST(JSON_EXTRACT(@view_no_meta, CONCAT('$."', j.k, '"')) AS CHAR)) AS equal_as_text,
       JSON_TYPE(JSON_EXTRACT(@manual, CONCAT('$."', j.k, '"'))) AS manual_type,
       JSON_TYPE(JSON_EXTRACT(@view_no_meta, CONCAT('$."', j.k, '"'))) AS view_type
FROM JSON_TABLE(JSON_KEYS(@manual), '$[*]' COLUMNS (k VARCHAR(64) PATH '$')) j;

SELECT '== 4b. same comparison for the first item and first payment' AS step;
SELECT (JSON_EXTRACT(@manual, '$.items[0]') = JSON_EXTRACT(@view_no_meta, '$.items[0]')) AS item0_equal,
       (JSON_EXTRACT(@manual, '$.items[1]') = JSON_EXTRACT(@view_no_meta, '$.items[1]')) AS item1_equal,
       (JSON_EXTRACT(@manual, '$.payments[0]') = JSON_EXTRACT(@view_no_meta, '$.payments[0]')) AS payment0_equal,
       (JSON_EXTRACT(@manual, '$.payments[1]') = JSON_EXTRACT(@view_no_meta, '$.payments[1]')) AS payment1_equal,
       JSON_TYPE(JSON_EXTRACT(@manual, '$.items[0].price')) AS manual_price_type,
       JSON_TYPE(JSON_EXTRACT(@view_no_meta, '$.items[0].price')) AS view_price_type;
-- 5. why does the whole-document comparison in step 3 say 0 when every key is equal?
SELECT '== 5. whole-document comparison after forcing both sides to JSON' AS step;
SELECT (CAST(@manual AS JSON) = CAST(@view_no_meta AS JSON))                   AS equal_cast_to_json,
       (JSON_PRETTY(CAST(@manual AS JSON)) = JSON_PRETTY(CAST(@view_no_meta AS JSON))) AS equal_pretty_text,
       JSON_CONTAINS(CAST(@manual AS JSON), CAST(@view_no_meta AS JSON))      AS manual_contains_view,
       JSON_CONTAINS(CAST(@view_no_meta AS JSON), CAST(@manual AS JSON))      AS view_contains_manual,
       CHAR_LENGTH(@manual) AS manual_text_chars, CHAR_LENGTH(@view_no_meta) AS view_text_chars,
       JSON_TYPE(@manual) AS manual_var_json_type, JSON_TYPE(@view_no_meta) AS view_var_json_type;
SELECT SUBSTRING(@manual, 1, 60) AS manual_start, SUBSTRING(@view_no_meta, 1, 60) AS view_start;