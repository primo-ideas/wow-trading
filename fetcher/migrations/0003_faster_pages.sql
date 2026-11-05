-- What a market page lists, worked out once per snapshot. Doing it for each reader takes
-- three aggregates over tens of thousands of rows, several times per page, for an answer
-- that only changes when a snapshot arrives. Names and icons are not here: they are
-- looked up later than the snapshot, and read from `items` and `pets` directly.
CREATE TABLE listed_products (
    auction_house_id       INTEGER NOT NULL REFERENCES auction_houses (id),
    item_id                INTEGER NOT NULL,
    -- 'pet:<species>' for a caged pet, as they all share one item. '' for anything else:
    -- gear adds up into one product, as its bonus lists mean nothing to a reader.
    series                 TEXT    NOT NULL,
    min_price              BIGINT  NOT NULL,
    -- Weighted by quantity: a variant listed once must not count like one listed 200 times.
    median_price           BIGINT,
    quantity               BIGINT  NOT NULL,
    auction_count          BIGINT  NOT NULL,
    variant_count          INTEGER NOT NULL,
    -- Over the day before the snapshot. NULL when nothing sold.
    sold_quantity          BIGINT,
    sold_value             BIGINT,
    -- The median about a day before the snapshot, and how much it moved since. NULL when
    -- the market has no snapshot from then, or this product was not on sale.
    reference_median_price BIGINT,
    change                 DOUBLE PRECISION,
    PRIMARY KEY (auction_house_id, item_id, series)
);

-- A function so that the fetcher and the site's tests run the same computation. Called in
-- the transaction that stores a snapshot, so readers go from one snapshot to the next at once.
--
-- In that transaction the new rows have no statistics yet. Believing them to be few, the
-- planner would join these aggregates with nested loops: measured on a realm of 13 000
-- products, 67 s rather than 0.4 s. All three are always large: nothing beats a hash join.
CREATE FUNCTION refresh_listed_products(house INTEGER) RETURNS VOID
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
        variant_count, sold_quantity, sold_value, reference_median_price, change
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
    )
    SELECT house, current_points.item_id, current_points.series, current_points.min_price,
           current_points.median_price, current_points.quantity, current_points.auction_count,
           current_points.variant_count, sold.sold_quantity, sold.sold_value,
           reference_points.median_price,
           (current_points.median_price - reference_points.median_price)::float8
             / NULLIF(reference_points.median_price, 0)
    FROM current_points
    LEFT JOIN sold USING (item_id, series)
    LEFT JOIN reference_points USING (item_id, series);
END;
$$;

SELECT refresh_listed_products(id) FROM auction_houses;

-- For the default sort of a market page, and "the most traded" above it.
CREATE INDEX listed_products_by_value ON listed_products (auction_house_id, sold_value DESC NULLS LAST);

-- Names without case or accents, to search them as a reader types. ILIKE cannot do this:
-- the database uses the C locale, where it only folds ASCII, and removing accents properly
-- would take an extension in a schema this app does not own. Stored, as lowercasing through
-- ICU for every name at every keystroke is what makes a search slow. web/app/models/text_search.rb
-- applies the same mapping to what the reader typed.
ALTER TABLE items ADD COLUMN search_name TEXT GENERATED ALWAYS AS (
    translate(lower(name COLLATE "und-x-icu"),
              'àáâãäåæçèéêëìíîïñòóôõöøœùúûüýÿ',
              'aaaaaaaceeeeiiiinooooooouuuuyy')
) STORED;
ALTER TABLE pets ADD COLUMN search_name TEXT GENERATED ALWAYS AS (
    translate(lower(name COLLATE "und-x-icu"),
              'àáâãäåæçèéêëìíîïñòóôõöøœùúûüýÿ',
              'aaaaaaaceeeeiiiinooooooouuuuyy')
) STORED;
