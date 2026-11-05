# A page of what is on sale on a realm's markets, as filtered and sorted by the reader.
class MarketListing
  PAGE_SIZE = 50
  DEFAULT_SORT = "value"
  # Column, and the direction a first click on its header sorts in.
  SORTS = {
    "name" => [ %(#{ListedProduct::NAME} COLLATE "und-x-icu"), "asc" ],
    "price" => [ "listed.median_price", "desc" ],
    "min" => [ "listed.min_price", "asc" ],
    "change" => [ "listed.change", "desc" ],
    "quantity" => [ "listed.quantity", "desc" ],
    "sold" => [ "listed.sold_quantity", "desc" ],
    "value" => [ "listed.sold_value", "desc" ]
  }.freeze
  # Far past any real listing, and keeps the offset within what Postgres accepts.
  MAX_PAGE = 100_000

  attr_reader :sort, :page, :query, :item_class, :quality

  def initialize(markets, query: nil, item_class: nil, quality: nil, sort: nil, dir: nil, page: nil)
    @market_query = MarketQuery.new(markets)
    @query = query.to_s.delete("\0").strip
    @item_class = item_class.to_s.delete("\0").presence
    @quality = quality.to_s.delete("\0").presence
    @sort = SORTS.key?(sort) ? sort : DEFAULT_SORT
    @dir = dir if %w[asc desc].include?(dir)
    @page = page.to_s.to_i.clamp(1, MAX_PAGE)
  end

  def dir = @dir || default_dir(sort)

  def default_dir(column) = SORTS.fetch(column).last

  def latest_taken_at = @market_query.latest_taken_at

  def compared? = @market_query.compared?

  def rows
    @rows ||= @market_query.products(
      where: filter, binds: filter_binds,
      order: "#{SORTS.fetch(sort).first} #{dir.upcase} NULLS LAST",
      limit: PAGE_SIZE, offset: (page - 1) * PAGE_SIZE
    )
  end

  def total
    @total ||= @market_query.count(where: filter, binds: filter_binds)
  end

  def page_count = [ (total.to_f / PAGE_SIZE).ceil, 1 ].max

  def next_page? = page < page_count

  def previous_page? = page > 1

  def filtered? = query.present? || item_class.present? || quality.present?

  def sparkline(row) = sparklines.for(row)

  private

  def sparklines
    @sparklines ||= Sparklines.new(rows, latest_taken_at)
  end

  def filter
    conditions = []
    conditions << "(#{TextSearch.condition(ListedProduct::SEARCH_NAME)} OR listed.item_id = :item_id)" if query.present?
    conditions << "items.item_class = :item_class" if item_class
    conditions << "items.quality = :quality" if quality
    conditions.join(" AND ").presence
  end

  def filter_binds
    {
      query: TextSearch.pattern(query),
      item_id: query.match?(/\A\d{1,9}\z/) ? query.to_i : nil,
      item_class: item_class,
      quality: quality
    }
  end
end
