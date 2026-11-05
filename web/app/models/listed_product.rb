# A product and its statistics on one market. The fetcher fills this table; names and
# icons come from `items` and `pets`, as they are looked up later than the snapshot.
class ListedProduct < ApplicationRecord
  NAME = "COALESCE(pets.name, items.name)".freeze
  SEARCH_NAME = "COALESCE(pets.search_name, items.search_name)".freeze
  LABELS ="#{NAME} AS name, COALESCE(pets.icon_url, items.icon_url) AS icon_url, items.quality".freeze
  FROM_WITH_LABELS = <<~SQL.squish.freeze
    FROM listed_products listed
    LEFT JOIN items ON items.id = listed.item_id
    LEFT JOIN pets ON pets.species_id = NULLIF(substring(listed.series FROM 5), '')::int
  SQL

  def display_name = name.presence || "Objet ##{item_id}"

  # Gear is listed once whatever its bonus lists: its page offers the variants.
  def variant_param = series.presence

  def several_variants? = variant_count.to_i > 1
end
