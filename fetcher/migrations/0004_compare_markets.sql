-- For an item page, which shows the same product on the other markets of its region.
CREATE INDEX listed_products_by_item ON listed_products (item_id, series);
