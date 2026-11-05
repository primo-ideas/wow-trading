# The products of one or more markets at their latest snapshot, as the fetcher worked
# them out when it stored that snapshot: see `listed_products` in its migrations. A
# realm reads two: its own auction house and the commodities of its region.
class MarketQuery
  def initialize(markets)
    @ids = Array(markets).map(&:id)
  end

  def latest_taken_at
    return @latest_taken_at if defined?(@latest_taken_at)

    @latest_taken_at = @ids.empty? ? nil : Snapshot.where(auction_house_id: @ids).maximum(:taken_at)
  end

  def compared?
    return @compared if defined?(@compared)

    @compared = ListedProduct.where(auction_house_id: @ids).where.not(reference_median_price: nil).exists?
  end

  def products(order:, limit:, offset: 0, where: nil, binds: {})
    ListedProduct.find_by_sql([ <<~SQL, binds.merge(houses: @ids, limit: limit, offset: offset) ])
      SELECT listed.*, #{ListedProduct::LABELS}
      #{ListedProduct::FROM_WITH_LABELS}
      WHERE #{conditions(where)}
      ORDER BY #{order}, listed.item_id, listed.series, listed.auction_house_id
      LIMIT :limit OFFSET :offset
    SQL
  end

  def count(where: nil, binds: {})
    ListedProduct.find_by_sql([ <<~SQL, binds.merge(houses: @ids) ]).first.total
      SELECT count(*) AS total
      #{ListedProduct::FROM_WITH_LABELS}
      WHERE #{conditions(where)}
    SQL
  end

  private

  def conditions(where)
    [ "listed.auction_house_id IN (:houses)", where ].compact.join(" AND ")
  end
end
