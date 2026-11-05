-- For an item page, which shows the same product on the other markets of its region.
CREATE INDEX listed_products_by_item ON listed_products (item_id, series);

-- What the cheapest listing of a product usually costs: the median of its cheapest price
-- over three days of snapshots, without the latest one. Deals are measured against this,
-- as the cheapest listing is what a buyer actually pays. Asking prices can be absurd with
-- nobody buying, and estimated sales count cancelled listings, so neither says what a
-- product is worth.
ALTER TABLE listed_products
    ADD COLUMN usual_min_price BIGINT,
    -- How many snapshots that comes from: a few say little.
    ADD COLUMN usual_min_points INTEGER NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION refresh_listed_products(house INTEGER) RETURNS VOID
LANGUAGE plpgsql
SET enable_nestloop = off
AS $$
DECLARE
    latest_at    TIMESTAMPTZ;
    reference_at TIMESTAMPTZ;
BEGIN
    SELECT max(taken_at) INTO latest_at FROM snapshots WHERE auction_house_id = house;
    -- Snapshots can be missing: up to 12 hours further back still makes a daily change.
    SELECT max(taken_at) INTO reference_at
    FROM snapshots
    WHERE auction_house_id = house
      AND taken_at BETWEEN latest_at - INTERVAL '36 hours' AND latest_at - INTERVAL '1 day';

    DELETE FROM listed_products WHERE auction_house_id = house;

    INSERT INTO listed_products (
        auction_house_id, item_id, series, min_price, median_price, quantity, auction_count,
        variant_count, sold_quantity, sold_value, reference_median_price, change,
        usual_min_price, usual_min_points
    )
    WITH current_points AS (
        SELECT item_id, CASE WHEN variant LIKE 'pet:%' THEN variant ELSE '' END AS series,
               min(min_price) AS min_price,
               (sum(median_price::numeric * quantity) / NULLIF(sum(quantity), 0))::bigint AS median_price,
               sum(quantity)::bigint AS quantity,
               sum(auction_count)::bigint AS auction_count,
               count(*)::integer AS variant_count
        FROM price_points
        WHERE auction_house_id = house AND taken_at = latest_at
        GROUP BY 1, 2
    ), reference_points AS (
        SELECT item_id, CASE WHEN variant LIKE 'pet:%' THEN variant ELSE '' END AS series,
               (sum(median_price::numeric * quantity) / NULLIF(sum(quantity), 0))::bigint AS median_price
        FROM price_points
        WHERE auction_house_id = house AND taken_at = reference_at
        GROUP BY 1, 2
    ), sold AS (
        SELECT item_id, CASE WHEN variant LIKE 'pet:%' THEN variant ELSE '' END AS series,
               sum(sold_quantity)::bigint AS sold_quantity,
               least(sum(sold_value), 9223372036854775807)::bigint AS sold_value
        FROM sales_points
        WHERE auction_house_id = house AND taken_at > latest_at - INTERVAL '1 day'
        GROUP BY 1, 2
    ), cheapest_by_snapshot AS (
        SELECT item_id, CASE WHEN variant LIKE 'pet:%' THEN variant ELSE '' END AS series,
               taken_at, min(min_price) AS min_price
        FROM price_points
        WHERE auction_house_id = house
          AND taken_at >= latest_at - INTERVAL '3 days' AND taken_at < latest_at
        GROUP BY 1, 2, 3
    ), usual AS (
        SELECT item_id, series,
               percentile_disc(0.5) WITHIN GROUP (ORDER BY min_price) AS min_price,
               count(*)::integer AS points
        FROM cheapest_by_snapshot
        GROUP BY 1, 2
    )
    SELECT house, current_points.item_id, current_points.series, current_points.min_price,
           current_points.median_price, current_points.quantity, current_points.auction_count,
           current_points.variant_count, sold.sold_quantity, sold.sold_value,
           reference_points.median_price,
           (current_points.median_price - reference_points.median_price)::float8
             / NULLIF(reference_points.median_price, 0),
           usual.min_price, COALESCE(usual.points, 0)
    FROM current_points
    LEFT JOIN sold USING (item_id, series)
    LEFT JOIN reference_points USING (item_id, series)
    LEFT JOIN usual USING (item_id, series);
END;
$$;

SELECT refresh_listed_products(id) FROM auction_houses;
