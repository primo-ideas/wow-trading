# The same product on the markets of a region. Gold stays within a region, so that is
# where comparing prices makes sense.
class ProductAcrossMarkets
  LIMIT = 12

  def initialize(market, item_id, series)
    @market = market
    @item_id = item_id
    @series = series
  end

  # The cheapest first.
  def rows
    @rows ||= ListedProduct
      .joins("JOIN auction_houses houses ON houses.id = listed_products.auction_house_id")
      .where(item_id: @item_id, series: @series)
      .where(houses: { region: @market.region })
      .select("listed_products.*, houses.name AS market_name")
      .order(:min_price, :auction_house_id)
      .limit(LIMIT)
      .to_a
  end

  def comparable? = rows.many?

  def current?(row) = row.auction_house_id == @market.id
end
