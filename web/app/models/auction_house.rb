class AuctionHouse < ApplicationRecord
  has_many :snapshots

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

  # The fetcher knows every realm of a region, but only follows some of them.
  scope :tracked, -> { with_latest_snapshot.where("latest.latest_taken_at IS NOT NULL") }

  scope :listing_order, -> {
    order(:region, Arel.sql("connected_realm_id IS NOT NULL"),
      Arel.sql('auction_houses.name COLLATE "und-x-icu"'))
  }

  def commodities? = connected_realm_id.nil?

  def display_name = commodities? ? "Matières premières" : name

  def latest_snapshot_at = snapshots.maximum(:taken_at)
end
