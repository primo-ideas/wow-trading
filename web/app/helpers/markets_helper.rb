module MarketsHelper
  # A column header that sorts by this column, and reverses when it already does.
  def sort_link(label, column, listing)
    current = listing.sort == column
    dir = if current
      listing.dir == "asc" ? "desc" : "asc"
    else
      listing.default_dir(column)
    end
    arrow = current ? (listing.dir == "asc" ? " ↑" : " ↓") : ""

    link_to "#{label}#{arrow}", market_path(@market, listing_params(listing).merge(sort: column, dir: dir)),
      class: ("is-sorted" if current), "aria-sort": (current ? (listing.dir == "asc" ? "ascending" : "descending") : nil)
  end

  # A column header that sorts the deals by this column, always in the same direction.
  def deals_sort_link(label, column, deals)
    current = deals.sort == column
    link_to "#{label}#{" ↓" if current}", deals_market_path(@market, sort: column),
      class: ("is-sorted" if current), "aria-sort": ("descending" if current)
  end

  def listing_page_path(market, listing, page)
    market_path(market, listing_params(listing).merge(sort: listing.sort, dir: listing.dir, page: page))
  end

  # Whatever the reader filtered on, without what is at its default.
  def listing_params(listing)
    { q: listing.query.presence, item_class: listing.item_class, quality: listing.quality }.compact
  end

  # The tabs of a market page: a player's realm, and the commodities of its region.
  def market_tabs(market)
    realm = market.commodities? ? remembered_realm_of(market.region) : market
    commodities = tracked_markets.find { |other| other.commodities? && other.region == market.region }
    [ realm, commodities ].compact
  end

  def short_market_name(market)
    truncate(market.display_name, length: 34, separator: " ")
  end
end
