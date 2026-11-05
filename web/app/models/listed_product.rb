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

  # About a day of snapshots: fewer say little about what is usual.
  MIN_USUAL_POINTS = 24

  def display_name = name.presence || "Item ##{item_id}"

  # What its cheapest listing usually costs. Not for gear in several variants, whose
  # prices have little to do with each other.
  def usual_price
    usual_min_price if variant_count == 1 && usual_min_points >= MIN_USUAL_POINTS && usual_min_price.positive?
  end

  # Buying the cheapest listing and selling at the usual price.
  def resale_profit = usual_price && Flip.profit(buy: min_price, sell: usual_price)

  def discount = usual_price && 1 - min_price.fdiv(usual_price)

  # Gear is listed once whatever its bonus lists: its page offers the variants.
  def variant_param = series.presence

  def several_variants? = variant_count.to_i > 1
end
