-- Conventions: prices are in copper (1g = 10 000 copper), timestamps are UTC.

-- One row per market: a connected realm, or the region-wide commodity market.
CREATE TABLE auction_houses (
    id                 INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region             TEXT NOT NULL,
    -- NULL for the commodity market.
    connected_realm_id INTEGER,
    name               TEXT NOT NULL,
    -- Raw Last-Modified of the latest ingested snapshot, sent back as If-Modified-Since.
    last_modified      TEXT,
    UNIQUE NULLS NOT DISTINCT (region, connected_realm_id)
);

CREATE TABLE realms (
    region           TEXT    NOT NULL,
    slug             TEXT    NOT NULL,
    name             TEXT    NOT NULL,
    auction_house_id INTEGER NOT NULL REFERENCES auction_houses (id),
    PRIMARY KEY (region, slug)
);

-- Ingestion log. The primary key is what makes re-ingesting a snapshot a no-op.
CREATE TABLE snapshots (
    auction_house_id  INTEGER     NOT NULL REFERENCES auction_houses (id),
    -- Last-Modified of the snapshot: when Blizzard generated it, not when we fetched it.
    taken_at          TIMESTAMPTZ NOT NULL,
    -- Previous snapshot of this market: sales are estimated over this interval.
    previous_taken_at TIMESTAMPTZ,
    fetched_at        TIMESTAMPTZ NOT NULL,
    auction_count     INTEGER     NOT NULL,
    -- Auctions without a buyout: they have no price to aggregate.
    unpriced_count    INTEGER     NOT NULL,
    PRIMARY KEY (auction_house_id, taken_at)
);

-- Auctions of the latest snapshot of each market, compared to the next snapshot
-- to estimate sales. One compressed document per market rather than one row per
-- auction, as every row would be replaced at each snapshot. Not meant for reading.
CREATE TABLE market_states (
    auction_house_id INTEGER     PRIMARY KEY REFERENCES auction_houses (id),
    taken_at         TIMESTAMPTZ NOT NULL,
    auctions         BYTEA       NOT NULL
);

-- The next two tables get one partition per day (see Store::ensure_partitions).
-- Old partitions are rolled up into the *_daily tables, then dropped.
-- Columns are ordered to avoid padding: these are by far the largest tables.

-- One row per item variant per snapshot. Quantiles are weighted by quantity.
CREATE TABLE price_points (
    auction_house_id INTEGER     NOT NULL,
    item_id          INTEGER     NOT NULL,
    taken_at         TIMESTAMPTZ NOT NULL,
    min_price        BIGINT      NOT NULL,
    p25_price        BIGINT      NOT NULL,
    median_price     BIGINT      NOT NULL,
    p75_price        BIGINT      NOT NULL,
    mean_price       BIGINT      NOT NULL,
    quantity         INTEGER     NOT NULL,
    auction_count    INTEGER     NOT NULL,
    -- '' for a plain item, 'pet:<species>' for a caged pet, 'bonus:<ids>' for gear.
    variant          TEXT        NOT NULL,
    PRIMARY KEY (auction_house_id, item_id, variant, taken_at)
) PARTITION BY RANGE (taken_at);

-- Estimated sales between `taken_at` and the previous snapshot of the market.
-- An estimate: a cancelled auction cannot be told apart from a sold one.
CREATE TABLE sales_points (
    auction_house_id INTEGER     NOT NULL,
    item_id          INTEGER     NOT NULL,
    taken_at         TIMESTAMPTZ NOT NULL,
    sold_value       BIGINT      NOT NULL,
    sold_quantity    INTEGER     NOT NULL,
    sold_auctions    INTEGER     NOT NULL,
    variant          TEXT        NOT NULL,
    PRIMARY KEY (auction_house_id, item_id, variant, taken_at)
) PARTITION BY RANGE (taken_at);

-- Prices are the average of the day's points, except the lowest minimum.
CREATE TABLE price_points_daily (
    auction_house_id INTEGER NOT NULL,
    item_id          INTEGER NOT NULL,
    day              DATE    NOT NULL,
    min_price        BIGINT  NOT NULL,
    p25_price        BIGINT  NOT NULL,
    median_price     BIGINT  NOT NULL,
    p75_price        BIGINT  NOT NULL,
    mean_price       BIGINT  NOT NULL,
    quantity         INTEGER NOT NULL,
    auction_count    INTEGER NOT NULL,
    variant          TEXT    NOT NULL,
    PRIMARY KEY (auction_house_id, item_id, variant, day)
);

CREATE TABLE sales_points_daily (
    auction_house_id INTEGER NOT NULL,
    item_id          INTEGER NOT NULL,
    day              DATE    NOT NULL,
    sold_value       BIGINT  NOT NULL,
    sold_quantity    INTEGER NOT NULL,
    sold_auctions    INTEGER NOT NULL,
    variant          TEXT    NOT NULL,
    PRIMARY KEY (auction_house_id, item_id, variant, day)
);

-- A row appears as soon as an item is seen on a market; metadata follows later.
CREATE TABLE items (
    id            INTEGER PRIMARY KEY,
    -- Stays NULL when the Item API does not know the item (see resolved_at).
    name          TEXT,
    quality       TEXT,
    level         INTEGER,
    item_class    TEXT,
    item_subclass TEXT,
    -- When the Item API last answered for this item; NULL if it never did.
    resolved_at   TIMESTAMPTZ
);
CREATE INDEX items_without_name ON items (resolved_at) WHERE name IS NULL;
