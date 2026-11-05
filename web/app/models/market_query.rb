# The products of a market at its latest snapshot, as the fetcher worked them out when
# it stored that snapshot: see `listed_products` in its migrations.
class MarketQuery
  def initialize(market)
    @market = market
  end

  def latest_taken_at
    return @latest_taken_at if defined?(@latest_taken_at)

    @latest_taken_at = @market.latest_snapshot_at
  end

  def compared?
    return @compared if defined?(@compared)

    @compared = ListedProduct.where(auction_house_id: @market.id).where.not(reference_median_price: nil).exists?
  end

  def products(order:, limit:, offset: 0, where: nil, binds: {})
    ListedProduct.find_by_sql([ <<~SQL, binds.merge(house: @market.id, limit: limit, offset: offset) ])
      SELECT listed.*, #{ListedProduct::LABELS}
      #{ListedProduct::FROM_WITH_LABELS}
      WHERE #{conditions(where)}
      ORDER BY #{order}, listed.item_id, listed.series
      LIMIT :limit OFFSET :offset
    SQL
  end

  def count(where: nil, binds: {})
    ListedProduct.find_by_sql([ <<~SQL, binds.merge(house: @market.id) ]).first.total
      SELECT count(*) AS total
      #{ListedProduct::FROM_WITH_LABELS}
      WHERE #{conditions(where)}
    SQL
  end

  private

  def conditions(where)
    [ "listed.auction_house_id = :house", where ].compact.join(" AND ")
  end
end
