-- URL of the item's icon on Blizzard's image server. NULL if not fetched yet, or
-- if the API has none (see resolved_at).
ALTER TABLE items ADD COLUMN icon_url TEXT;

-- Items resolved before icons existed need another lookup.
UPDATE items SET resolved_at = NULL;

DROP INDEX items_without_name;
CREATE INDEX items_to_resolve ON items (resolved_at) WHERE name IS NULL OR icon_url IS NULL;

-- Caged pets all share one item (see `variant`): their name and icon are per species.
-- A row appears as soon as a species is seen on a market; metadata follows later.
CREATE TABLE pets (
    species_id  INTEGER PRIMARY KEY,
    -- Stays NULL when the Pet API does not know the species (see resolved_at).
    name        TEXT,
    icon_url    TEXT,
    -- When the Pet API last answered for this species; NULL if it never did.
    resolved_at TIMESTAMPTZ
);
CREATE INDEX pets_to_resolve ON pets (resolved_at) WHERE name IS NULL OR icon_url IS NULL;
