# What a reader follows, kept in a cookie: the site has no accounts, and never writes to
# its database. Products, not prices on a given market: the list shows them on whatever
# realm the reader is on.
class Watchlist
  # A cookie holds 4 KB, which this stays well under. The oldest entries go first.
  LIMIT = 100
  Entry = Data.define(:item_id, :series)
  ENTRY = /\A(\d{1,9})(?:\.(\d{1,9}))?\z/
  # The cookie of the time products were followed market by market: market.item[.species].
  LEGACY_ENTRY = /\A\d{1,9}\.(\d{1,9})(?:\.(\d{1,9}))?\z/
  SERIES = /\A(?:pet:(\d{1,9}))?\z/

  attr_reader :entries

  def initialize(cookie, legacy: nil)
    texts, pattern = cookie.nil? ? [ legacy, LEGACY_ENTRY ] : [ cookie, ENTRY ]
    @entries = texts.to_s.split("_").filter_map { |text| parse(text, pattern) }.uniq.last(LIMIT)
  end

  def include?(item_id, series) = entries.include?(Entry.new(item_id, series))

  def empty? = entries.empty?

  def size = entries.size

  # Adds the product, or removes it if it was there. Anything malformed changes nothing.
  def toggle(item_id, series)
    return unless item_id.to_s.match?(/\A\d{1,9}\z/) && series.to_s.match?(SERIES)

    entry = Entry.new(item_id.to_i, series.to_s)
    @entries = entries.include?(entry) ? entries - [ entry ] : (entries + [ entry ]).last(LIMIT)
    @products = nil
  end

  # Only characters a cookie carries as they are, so that the limit above holds.
  def to_cookie
    entries.map { |entry| [ entry.item_id, entry.series.delete_prefix("pet:").presence ].compact.join(".") }.join("_")
  end

  # What is on sale on these markets at their latest snapshot, with its name and icon.
  def products(markets)
    return [] if empty? || markets.empty?

    @products ||= {}
    @products[markets.map(&:id)] ||= ListedProduct.find_by_sql([ <<~SQL, houses: markets.map(&:id), items: entries.map(&:item_id).uniq ])
      SELECT listed.*, #{ListedProduct::LABELS}
      #{ListedProduct::FROM_WITH_LABELS}
      WHERE listed.auction_house_id IN (:houses) AND listed.item_id IN (:items)
      ORDER BY #{ListedProduct::NAME} COLLATE "und-x-icu", listed.item_id, listed.series
    SQL
      .select { |row| include?(row.item_id, row.series) }
  end

  def not_on_sale(markets) = size - products(markets).size

  private

  def parse(text, pattern)
    item_id, species = text.match(pattern)&.captures
    Entry.new(item_id.to_i, species ? "pet:#{species}" : "") if item_id
  end
end
