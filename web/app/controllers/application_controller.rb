class ApplicationController < ActionController::Base
  helper_method :tracked_markets, :remembered_market, :remembered_realm_of, :search_markets

  # The fetcher creates the schema on its first run, which may not have happened yet.
  rescue_from ActiveRecord::StatementInvalid do |error|
    raise error unless error.cause.is_a?(PG::UndefinedTable)

    # The header lists markets, from a table that is missing as well.
    @tracked_markets = []
    render "errors/not_ready", status: :service_unavailable
  end

  private

  def tracked_markets
    @tracked_markets ||= AuctionHouse.tracked.listing_order.to_a
  end

  # A player thinks in terms of their realm: browsing the commodities of its region
  # does not change it, so the realm is what gets remembered.
  def remembered_market
    return @remembered_market if defined?(@remembered_market)

    @remembered_market = tracked_markets.find { |market| market.id == cookies[:market].to_i }
  end

  def remember(market)
    return if market.commodities? && remembered_market && remembered_market.region == market.region

    cookies[:market] = { value: market.id, expires: 1.year, same_site: :lax, path: cookie_path }
    @remembered_market = tracked_markets.find { |tracked| tracked.id == market.id }
  end

  # Other sites may share the domain: this one's cookies stay within its path.
  def cookie_path = request.script_name.presence || "/"

  def remembered_realm_of(region)
    remembered_market if remembered_market&.region == region && !remembered_market.commodities?
  end

  # Where a search looks: the player's market and the commodities of its region.
  def search_markets
    return tracked_markets.first(10) unless remembered_market

    tracked_markets.select do |market|
      market.id == remembered_market.id ||
        (market.commodities? && market.region == remembered_market.region)
    end
  end
end
