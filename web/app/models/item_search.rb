# Finds what is on sale by name, on the markets a player cares about: their realm and
# the commodities of its region, which is where they would look for it in game.
class ItemSearch
  MIN_LENGTH = 2
  LIMIT = 8

  attr_reader :query

  def initialize(query, markets, limit: LIMIT)
    @query = query.to_s.delete("\0").strip
    @markets = markets
    @limit = limit
  end

  def searchable? = query.length >= MIN_LENGTH

  def results
    return [] unless searchable?

    @results ||= ListedProduct.find_by_sql([ <<~SQL, houses: @markets.map(&:id), query: TextSearch.pattern(query), prefix: "#{TextSearch.escape(query)}%", limit: @limit ])
      SELECT listed.*, #{ListedProduct::LABELS}
      #{ListedProduct::FROM_WITH_LABELS}
      WHERE listed.auction_house_id IN (:houses) AND #{TextSearch.condition(ListedProduct::SEARCH_NAME)}
      ORDER BY #{TextSearch.condition(ListedProduct::SEARCH_NAME, bind: ":prefix")} DESC,
               listed.quantity DESC, listed.item_id, listed.series
      LIMIT :limit
    SQL
  end

  def market_of(result) = @markets.find { |market| market.id == result.auction_house_id }
end
