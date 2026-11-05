# What a reader follows, kept in a cookie: the site has no accounts, and never writes to
# its database.
class Watchlist
  # A cookie holds 4 KB, which this stays well under. The oldest entries go first.
  LIMIT = 100
  Entry = Data.define(:market_id, :item_id, :series)
  ENTRY = /\A(\d{1,9})\.(\d{1,9})(?:\.(\d{1,9}))?\z/
  SERIES = /\A(?:pet:(\d{1,9}))?\z/

  attr_reader :entries

  def initialize(cookie)
    @entries = cookie.to_s.split("_").filter_map { |text| parse(text) }.uniq.last(LIMIT)
  end

  def include?(market_id, item_id, series) = entries.include?(Entry.new(market_id, item_id, series))

  def empty? = entries.empty?

  def size = entries.size

  # Adds the product, or removes it if it was there. Anything malformed changes nothing.
  def toggle(market_id, item_id, series)
    return unless market_id.to_s.match?(/\A\d{1,9}\z/) && item_id.to_s.match?(/\A\d{1,9}\z/) && series.to_s.match?(SERIES)

    entry = Entry.new(market_id.to_i, item_id.to_i, series.to_s)
    @entries = entries.include?(entry) ? entries - [ entry ] : (entries + [ entry ]).last(LIMIT)
    @products = nil
  end

  # Only characters a cookie carries as they are, so that the limit above holds.
  def to_cookie
    entries.map { |entry| [ entry.market_id, entry.item_id, entry.series.delete_prefix("pet:").presence ].compact.join(".") }.join("_")
  end

  # What is on sale at the latest snapshot of each market, with its name and icon.
  def products
    return [] if empty?

    @products ||= ListedProduct.find_by_sql([ <<~SQL, houses: entries.map(&:market_id).uniq, items: entries.map(&:item_id).uniq ])
      SELECT listed.*, #{ListedProduct::LABELS}
      #{ListedProduct::FROM_WITH_LABELS}
      WHERE listed.auction_house_id IN (:houses) AND listed.item_id IN (:items)
      ORDER BY #{ListedProduct::NAME} COLLATE "und-x-icu", listed.item_id, listed.series
    SQL
      .select { |row| include?(row.auction_house_id, row.item_id, row.series) }
  end

  def not_on_sale = size - products.size

  private

  def parse(text)
    market_id, item_id, species = text.match(ENTRY)&.captures
    Entry.new(market_id.to_i, item_id.to_i, species ? "pet:#{species}" : "") if market_id
  end
end
