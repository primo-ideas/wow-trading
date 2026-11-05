# A market: the auction house that connected realms share, or the commodities of a
# region, which every realm of it trades on. Players never see these: the site shows
# them a realm, and adds both up.
class AuctionHouse < ApplicationRecord
  has_many :snapshots

  # The fetcher knows every realm of a region, but only follows some of them.
  scope :tracked, -> { where("EXISTS (SELECT 1 FROM snapshots WHERE snapshots.auction_house_id = auction_houses.id)") }

  def commodities? = connected_realm_id.nil?

  def latest_snapshot_at = snapshots.maximum(:taken_at)
end
