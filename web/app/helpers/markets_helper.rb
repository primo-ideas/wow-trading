module MarketsHelper
  def sort_link(label, sort, listing)
    current = listing.sort == sort
    link_to label, listing_params_path(listing, sort: sort, page: nil),
      class: ("is-sorted" if current), "aria-current": ("true" if current)
  end

  def listing_page_path(market, listing, page)
    market_path(market, listing_params(listing).merge(page: page))
  end

  private

  def listing_params_path(listing, overrides)
    url_for(listing_params(listing).merge(overrides))
  end

  def listing_params(listing)
    { q: listing.query.presence, sort: listing.sort }
  end
end
