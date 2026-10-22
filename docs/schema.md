# Schema reference

Table reference for the relational schema. Everything here is read from
[`sql/01_schema.sql`](../sql/01_schema.sql) (tables, keys, indexes, checks and
the three triggers it defines); nothing is tested or claimed beyond what that
file declares. For how the tables relate and which duality views sit on them,
see [`architecture.md`](architecture.md) (sections 3 and 4); for test evidence,
see [`findings.md`](findings.md).

All tables are `ENGINE=InnoDB`. Every `id` is `BIGINT UNSIGNED AUTO_INCREMENT
PRIMARY KEY`. In the tables below, `ts` stands for `DATETIME(6)`. A column
named `created_at` is `ts NOT NULL DEFAULT CURRENT_TIMESTAMP(6)`, and
`updated_at` is `ts NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE
CURRENT_TIMESTAMP(6)`; `deleted_at` is `ts NULL`.

Tables in creation order: [`businesses`](#businesses),
[`outlets`](#outlets), [`staff`](#staff), [`customers`](#customers),
[`products`](#products), [`product_variants`](#product_variants),
[`gst_rate_history`](#gst_rate_history), [`orders`](#orders),
[`order_items`](#order_items), [`payments`](#payments).

## businesses

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `name` | VARCHAR(255) | no | |
| `gst_percent` | DECIMAL(5,2) | no | 0 |
| `default_unit` | ENUM('kg','lb') | no | 'kg' |
| `is_active` | TINYINT | no | 1 |
| `created_at`, `updated_at` | ts | no | as above |
| `deleted_at` | ts | yes | |

Foreign keys: none. Triggers: none.

## outlets

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `business_id` | BIGINT UNSIGNED | no | |
| `name` | VARCHAR(255) | no | |
| `address` | TEXT | yes | |
| `is_active` | TINYINT | no | 1 |
| `created_at`, `updated_at` | ts | no | as above |
| `deleted_at` | ts | yes | |

- Foreign key `fk_outlets_business`: `business_id` → `businesses(id)`.
- Index `idx_outlets_business (business_id)`.
- Triggers: none.

## staff

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `business_id` | BIGINT UNSIGNED | no | |
| `outlet_id` | BIGINT UNSIGNED | yes | |
| `name` | VARCHAR(255) | no | |
| `is_active` | TINYINT | no | 1 |
| `created_at`, `updated_at` | ts | no | as above |

- Foreign keys: `fk_staff_business` (`business_id` → `businesses(id)`),
  `fk_staff_outlet` (`outlet_id` → `outlets(id)`).
- Indexes: `idx_staff_business (business_id)`, `idx_staff_outlet (outlet_id)`.
- Triggers: none.

## customers

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `business_id` | BIGINT UNSIGNED | no | |
| `name` | VARCHAR(255) | no | |
| `phone` | VARCHAR(20) | no | |
| `address` | TEXT | yes | |
| `is_active` | TINYINT | no | 1 |
| `created_at`, `updated_at` | ts | no | as above |
| `deleted_at` | ts | yes | |

- Foreign key `fk_customers_business`: `business_id` → `businesses(id)`.
- Unique `uq_customers_business_phone (business_id, phone)`.
- Index `idx_customers_business (business_id)`.
- Triggers: none.

## products

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `business_id` | BIGINT UNSIGNED | no | |
| `name` | VARCHAR(255) | no | |
| `price` | DECIMAL(10,2) | no | 0 |
| `is_mrp` | TINYINT | no | 0 |
| `gst_applicable` | TINYINT | no | 1 |
| `gst_rate` | DECIMAL(5,2) | no | 0 |
| `is_gst_inclusive` | TINYINT | no | 0 |
| `discount_exempt` | TINYINT | no | 0 |
| `max_discount_amount` | DECIMAL(10,2) | yes | |
| `is_active` | TINYINT | no | 1 |
| `created_at`, `updated_at` | ts | no | as above |
| `deleted_at` | ts | yes | |

- Foreign key `fk_products_business`: `business_id` → `businesses(id)`.
- Index `idx_products_business (business_id)`.
- Triggers: none.

## product_variants

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `product_id` | BIGINT UNSIGNED | no | |
| `flavor` | VARCHAR(255) | yes | |
| `size` | DECIMAL(6,2) | yes | |
| `unit` | ENUM('kg','lb') | yes | |
| `price` | DECIMAL(10,2) | no | 0 |
| `is_active` | TINYINT | no | 1 |
| `created_at`, `updated_at` | ts | no | as above |
| `deleted_at` | ts | yes | |

- Foreign key `fk_variants_product`: `product_id` → `products(id)`.
- Index `idx_variants_product (product_id)`.
- Triggers: none.

## gst_rate_history

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `business_id` | BIGINT UNSIGNED | no | |
| `gst_percent` | DECIMAL(5,2) | no | |
| `effective_from` | ts | no | CURRENT_TIMESTAMP(6) |
| `changed_by_staff_id` | BIGINT UNSIGNED | yes | |
| `created_at` | ts | no | as above |

- Foreign keys: `fk_gst_history_business` (`business_id` →
  `businesses(id)`), `fk_gst_history_staff` (`changed_by_staff_id` →
  `staff(id)`).
- Index `idx_gst_history_business (business_id)`.
- Triggers: none. No duality view is defined on this table
  (`sql/02_duality_views.sql`).

## orders

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `business_id` | BIGINT UNSIGNED | no | |
| `outlet_id` | BIGINT UNSIGNED | no | |
| `customer_id` | BIGINT UNSIGNED | no | |
| `created_by_staff_id` | BIGINT UNSIGNED | yes | |
| `request_id` | VARCHAR(64) | no | |
| `order_status` | ENUM('draft','confirmed','ready','delivered','cancelled') | no | 'draft' |
| `delivery_address` | TEXT | yes | |
| `delivery_at` | ts | yes | |
| `subtotal` | DECIMAL(10,2) | no | 0 |
| `discount_type` | ENUM('amount','percent') | no | 'amount' |
| `discount_value` | DECIMAL(10,2) | no | 0 |
| `gst_percent` | DECIMAL(5,2) | no | 0 |
| `gst_value` | DECIMAL(10,2) | no | 0 |
| `total` | DECIMAL(10,2) | no | 0 |
| `cancellation_reason` | TEXT | yes | |
| `created_at`, `updated_at` | ts | no | as above |
| `deleted_at` | ts | yes | |

- Unique `uq_orders_request_id (request_id)`.
- Foreign keys: `fk_orders_business` (`business_id` → `businesses(id)`),
  `fk_orders_outlet` (`outlet_id` → `outlets(id)`), `fk_orders_customer`
  (`customer_id` → `customers(id)`), `fk_orders_staff`
  (`created_by_staff_id` → `staff(id)`).
- Indexes: `idx_orders_business (business_id)`, `idx_orders_outlet
  (outlet_id)`, `idx_orders_customer (customer_id)`.
- Triggers defined in `sql/01_schema.sql`: `trg_orders_guards_ins` (BEFORE
  INSERT) and `trg_orders_guards_upd` (BEFORE UPDATE). Each checks GUARD 3
  (`total` against `subtotal - discount_value + gst_value`, difference greater
  than 0.01 rejected) and GUARD 4 (customer and outlet belong to
  `orders.business_id`).

## order_items

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `order_id` | BIGINT UNSIGNED | no | |
| `product_id` | BIGINT UNSIGNED | yes | |
| `product_variant_id` | BIGINT UNSIGNED | yes | |
| `name` | VARCHAR(255) | no | |
| `flavor` | VARCHAR(255) | yes | |
| `size` | DECIMAL(6,2) | yes | |
| `unit` | ENUM('kg','lb') | yes | |
| `occasion` | VARCHAR(255) | yes | |
| `dietary_flag` | VARCHAR(255) | yes | |
| `qty` | DECIMAL(6,2) | no | 1 |
| `price` | DECIMAL(10,2) | no | 0 |
| `gst_rate` | DECIMAL(5,2) | no | 0 |
| `is_gst_inclusive` | TINYINT | no | 0 |
| `gst_applicable` | TINYINT | no | 1 |
| `discount_exempt` | TINYINT | no | 0 |
| `max_discount_amount` | DECIMAL(10,2) | yes | |
| `gst_value` | DECIMAL(10,2) | no | 0 |
| `discount_value` | DECIMAL(10,2) | no | 0 |
| `notes` | TEXT | yes | |
| `is_active` | TINYINT | no | 1 |
| `created_at`, `updated_at` | ts | no | as above |
| `deleted_at` | ts | yes | |

- Check `chk_order_items_qty`: `qty > 0` (GUARD 1).
- Foreign keys: `fk_items_order` (`order_id` → `orders(id)`),
  `fk_items_product` (`product_id` → `products(id)`), `fk_items_variant`
  (`product_variant_id` → `product_variants(id)`).
- Indexes: `idx_items_order (order_id)`, `idx_items_product (product_id)`,
  `idx_items_variant (product_variant_id)`.
- Triggers defined in `sql/01_schema.sql`: none (see the note below).

## payments

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | no | AUTO_INCREMENT, primary key |
| `order_id` | BIGINT UNSIGNED | no | |
| `business_id` | BIGINT UNSIGNED | no | |
| `request_id` | VARCHAR(64) | no | |
| `payment_type` | ENUM('advance','installment','final','refund','udhaar_settlement') | no | |
| `method` | ENUM('cash','upi','card','other') | no | |
| `amount` | DECIMAL(10,2) | no | |
| `paid_at` | ts | no | CURRENT_TIMESTAMP(6) |
| `created_by_staff_id` | BIGINT UNSIGNED | yes | |
| `created_at`, `updated_at` | ts | no | as above |
| `deleted_at` | ts | yes | |

- Unique `uq_payments_request_id (request_id)`.
- Check `chk_payments_amount_sign` (GUARD 2): a `refund` has `amount < 0`; any
  other `payment_type` has `amount > 0`.
- Foreign keys: `fk_payments_order` (`order_id` → `orders(id)`),
  `fk_payments_business` (`business_id` → `businesses(id)`),
  `fk_payments_staff` (`created_by_staff_id` → `staff(id)`).
- Indexes: `idx_payments_order (order_id)`, `idx_payments_business
  (business_id)`.
- Triggers defined in `sql/01_schema.sql`: `trg_payments_guard_immutable`
  (BEFORE UPDATE), which rejects any change to the columns `id`, `order_id`,
  `business_id`, `request_id`, `payment_type`, `method`, `amount`, `paid_at`,
  `created_by_staff_id`, `created_at` and `deleted_at` (GUARD 5).

## Triggers in `sql/01_schema.sql`

| Trigger | Table | Event | Guard |
|---|---|---|---|
| `trg_orders_guards_ins` | `orders` | BEFORE INSERT | GUARD 3, GUARD 4 |
| `trg_orders_guards_upd` | `orders` | BEFORE UPDATE | GUARD 3, GUARD 4 |
| `trg_payments_guard_immutable` | `payments` | BEFORE UPDATE | GUARD 5 |

Other scripts create further triggers on these tables; they are not defined in
`sql/01_schema.sql` and are only named here: `trg_order_items_guard_ins`,
`trg_order_items_guard_upd` and `trg_payments_guard_business_ins`
(`sql/06_guards_6_7.sql`), and `trg_order_items_guard_tenant_ins` and
`trg_orders_guard_business_immutable` (`sql/09_guard_8.sql`). The guard map is
in [`architecture.md`](architecture.md) section 8.
