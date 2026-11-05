# What stands out on a realm's markets over the last day.
class MarketMovers
  LIMIT = 5
  # Below this, one listing added or removed swings the median: that is noise, not news.
  MIN_AUCTIONS = 5
  CHANGED = "listed.auction_count >= :min_auctions AND listed.reference_median_price IS NOT NULL".freeze
  # "Item #244630, +45%" tells a reader nothing. The listing below still has it.
  NAMED = "#{ListedProduct::NAME} IS NOT NULL".freeze

  def initialize(markets)
    @query = MarketQuery.new(markets)
  end

  def compared? = @query.compared?

  def risers
    @risers ||= products("listed.change DESC", "#{CHANGED} AND listed.median_price > listed.reference_median_price")
  end

  def fallers
    @fallers ||= products("listed.change ASC", "#{CHANGED} AND listed.median_price < listed.reference_median_price")
  end

  def most_traded
    @most_traded ||= products("listed.sold_value DESC NULLS LAST", "listed.sold_value > 0")
  end

  private

  def products(order, where)
    @query.products(where: "#{NAMED} AND #{where}", order: order, limit: LIMIT, binds: { min_auctions: MIN_AUCTIONS })
  end
end
