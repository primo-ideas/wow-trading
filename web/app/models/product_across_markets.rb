# The same product on the other realms of a region. Gold stays within a region, so that
# is where comparing prices makes sense. Connected realms share a market, so each row
# stands for one or more realms.
class ProductAcrossMarkets
  LIMIT = 12

  def initialize(market, item_id, series, realm: nil)
    @market = market
    @item_id = item_id
    @series = series
    @realm = realm
  end

  # The cheapest first.
  def rows
    @rows ||= ListedProduct
      .joins("JOIN auction_houses houses ON houses.id = listed_products.auction_house_id")
      .where(item_id: @item_id, series: @series)
      .where(houses: { region: @market.region })
      .order(:min_price, :auction_house_id)
      .limit(LIMIT)
      .to_a
  end

  def comparable? = rows.many?

  def current?(row) = row.auction_house_id == @market.id

  # The realms of a row, by name, with the reader's own first on its row.
  def realms_of(row)
    realms = realms_by_market.fetch(row.auction_house_id, [])
    current?(row) && @realm ? [ @realm, *realms.reject { |realm| realm == @realm } ] : realms
  end

  private

  def realms_by_market
    @realms_by_market ||= Realm.where(auction_house_id: rows.map(&:auction_house_id)).by_name.group_by(&:auction_house_id)
  end
end
