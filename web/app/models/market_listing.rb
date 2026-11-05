# What is on sale on a market at its latest snapshot, one row per item variant.
class MarketListing
  PAGE_SIZE = 100
  DEFAULT_SORT = "value"
  # Every order ends on the primary key, so that pages do not overlap.
  SORTS = {
    "value" => "sold.sold_value DESC NULLS LAST",
    "name" => 'i.name COLLATE "und-x-icu" ASC NULLS LAST',
    "price" => "p.median_price DESC",
    "quantity" => "p.quantity DESC"
  }.freeze

  # How far from exactly a day ago a snapshot can be and still give a daily change.
  REFERENCE_TOLERANCE = 12.hours
  # Far past any real listing, and keeps the offset within what Postgres accepts.
  MAX_PAGE = 100_000

  attr_reader :sort, :page, :query

  def initialize(market, query: nil, sort: nil, page: nil)
    @market = market
    @query = query.to_s.delete("\0").strip
    @sort = SORTS.key?(sort) ? sort : DEFAULT_SORT
    @page = page.to_s.to_i.clamp(1, MAX_PAGE)
  end

  def latest_taken_at
    return @latest_taken_at if defined?(@latest_taken_at)

    @latest_taken_at = @market.latest_snapshot_at
  end

  def rows = fetched.first(PAGE_SIZE)

  def next_page? = fetched.size > PAGE_SIZE

  def previous_page? = page > 1

  private

  def fetched
    @fetched ||= latest_taken_at ? PricePoint.find_by_sql([ sql, binds ]) : []
  end

  def reference_taken_at
    day_ago = latest_taken_at - 1.day
    @market.snapshots
      .where(taken_at: (day_ago - REFERENCE_TOLERANCE)..day_ago)
      .maximum(:taken_at)
  end

  def binds
    {
      house: @market.id,
      latest: latest_taken_at,
      since: latest_taken_at - 1.day,
      reference: reference_taken_at,
      # One more than a page: the extra row says whether there is a next page.
      limit: PAGE_SIZE + 1,
      offset: (page - 1) * PAGE_SIZE,
      query: TextSearch.pattern(query),
      item_id: query.match?(/\A\d{1,9}\z/) ? query.to_i : nil
    }
  end

  def sql
    <<~SQL
      WITH sold AS (
        SELECT item_id, variant,
               sum(sold_quantity)::bigint AS sold_quantity,
               least(sum(sold_value), 9223372036854775807)::bigint AS sold_value
        FROM sales_points
        WHERE auction_house_id = :house AND taken_at > :since
        GROUP BY item_id, variant
      )
      SELECT p.item_id, p.variant, p.min_price, p.median_price, p.quantity, p.auction_count,
             i.name, i.quality,
             sold.sold_quantity, sold.sold_value,
             reference.median_price AS reference_median_price
      FROM price_points p
      LEFT JOIN items i ON i.id = p.item_id
      LEFT JOIN sold ON sold.item_id = p.item_id AND sold.variant = p.variant
      LEFT JOIN price_points reference
        ON reference.auction_house_id = p.auction_house_id
       AND reference.item_id = p.item_id
       AND reference.variant = p.variant
       AND reference.taken_at = :reference
      WHERE p.auction_house_id = :house AND p.taken_at = :latest
      #{"AND (#{TextSearch.condition("i.name")} OR p.item_id = :item_id)" if query.present?}
      ORDER BY #{SORTS.fetch(sort)}, p.item_id, p.variant
      LIMIT :limit OFFSET :offset
    SQL
  end
end
