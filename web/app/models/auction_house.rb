class AuctionHouse < ApplicationRecord
  has_many :snapshots

  # Commodity markets are region-wide, so they stay listed whatever the search.
  scope :matching, ->(query) {
    next all if query.blank?

    where("connected_realm_id IS NULL OR #{TextSearch.condition("auction_houses.name")}",
      query: TextSearch.pattern(query))
  }

  scope :with_latest_snapshot, -> {
    joins(<<~SQL.squish)
      LEFT JOIN LATERAL (
        SELECT taken_at AS latest_taken_at, auction_count AS latest_auction_count
        FROM snapshots
        WHERE snapshots.auction_house_id = auction_houses.id
        ORDER BY taken_at DESC
        LIMIT 1
      ) latest ON true
    SQL
      .select("auction_houses.*, latest.latest_taken_at, latest.latest_auction_count")
  }

  scope :listing_order, -> {
    order(:region, Arel.sql("connected_realm_id IS NOT NULL"),
      Arel.sql('auction_houses.name COLLATE "und-x-icu"'))
  }

  def commodities? = connected_realm_id.nil?

  def display_name = commodities? ? "Matières premières" : name

  def latest_snapshot_at = snapshots.maximum(:taken_at)
end
