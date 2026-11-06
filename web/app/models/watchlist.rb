# What a reader follows, kept in a cookie: the site has no accounts, and never writes to
# its database. Products, not prices on a given market: the list shows them on whatever
# realm the reader is on. Each may carry a target price, which its cheapest listing is
# compared to.
class Watchlist
  # A cookie holds 4 KB, which this stays under even with a target on every product. The
  # oldest entries go first.
  LIMIT = 100
  Entry = Data.define(:item_id, :series, :target)
  ENTRY = /\A(\d{1,9})(?:\.(\d{1,9}))?(?:-(\d{1,13}))?\z/
  # The cookie of the time products were followed market by market: market.item[.species].
  LEGACY_ENTRY = /\A\d{1,9}\.(\d{1,9})(?:\.(\d{1,9}))?\z/
  SERIES = /\A(?:pet:(\d{1,9}))?\z/

  attr_reader :entries

  def initialize(cookie, legacy: nil)
    texts, pattern = cookie.nil? ? [ legacy, LEGACY_ENTRY ] : [ cookie, ENTRY ]
    @entries = texts.to_s.split("_").filter_map { |text| parse(text, pattern) }
      .uniq { |entry| [ entry.item_id, entry.series ] }.last(LIMIT)
  end

  def include?(item_id, series) = !entry_for(item_id, series).nil?

  def target_for(item_id, series) = entry_for(item_id, series)&.target

  def empty? = entries.empty?

  def size = entries.size

  def targets? = entries.any?(&:target)

  # Adds the product, or removes it if it was there. Anything malformed changes nothing.
  def toggle(item_id, series)
    return unless valid?(item_id, series)

    item_id = item_id.to_i
    series = series.to_s
    @entries = if include?(item_id, series)
      entries.reject { |entry| same?(entry, item_id, series) }
    else
      (entries + [ Entry.new(item_id, series, nil) ]).last(LIMIT)
    end
    @products = nil
  end

  # Sets the target price of a product, which follows it from then on; nil takes the
  # target off and keeps following it.
  def set_target(item_id, series, target)
    return unless valid?(item_id, series)
    return unless target.nil? || (target.is_a?(Integer) && target.between?(1, MoneyInput::MAX))

    item_id = item_id.to_i
    series = series.to_s
    entry = Entry.new(item_id, series, target)
    @entries = if include?(item_id, series)
      entries.map { |existing| same?(existing, item_id, series) ? entry : existing }
    else
      (entries + [ entry ]).last(LIMIT)
    end
    @products = nil
  end

  # Only characters a cookie carries as they are, so that the limit above holds.
  def to_cookie
    entries.map do |entry|
      text = [ entry.item_id, entry.series.delete_prefix("pet:").presence ].compact.join(".")
      entry.target ? "#{text}-#{entry.target}" : text
    end.join("_")
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

  # Whether the cheapest listing of this product is at or below its target.
  def at_target?(row)
    target = target_for(row.item_id, row.series)
    !target.nil? && row.min_price <= target
  end

  # The products whose cheapest listing has come down to their target on these markets.
  def at_target(markets)
    targets? ? products(markets).select { |row| at_target?(row) } : []
  end

  private

  def entry_for(item_id, series) = entries.find { |entry| same?(entry, item_id, series) }

  def same?(entry, item_id, series) = entry.item_id == item_id && entry.series == series

  def valid?(item_id, series)
    item_id.to_s.match?(/\A\d{1,9}\z/) && series.to_s.match?(SERIES)
  end

  def parse(text, pattern)
    item_id, species, target = text.match(pattern)&.captures
    return unless item_id

    target = target&.to_i
    Entry.new(item_id.to_i, species ? "pet:#{species}" : "", target&.between?(1, MoneyInput::MAX) ? target : nil)
  end
end
