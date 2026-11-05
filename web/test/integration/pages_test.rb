require "test_helper"

class PagesTest < ActionDispatch::IntegrationTest
  setup do
    @market = create_market(name: "Archimonde / Naxxramas")
  end

  def seed_item
    create_item(2589, name: "Linen Cloth", icon_url: "https://render.example/2589.jpg")
    create_snapshot(@market, NOW, auction_count: 42)
    create_snapshot(@market, NOW - 1.day)
    create_price(@market, 2589, NOW, median: 123_456)
    create_price(@market, 2589, NOW - 1.day, median: 100_000)
    create_sale(@market, 2589, NOW, quantity: 3, value: 30_000)
  end

  def create_commodities
    market = create_market(connected_realm_id: nil, name: "Commodities")
    create_snapshot(market, NOW)
    market
  end

  test "the health check answers" do
    get "/up"

    assert_response :success
  end

  test "before the fetcher's first run, the site says so rather than fail" do
    connection = ActiveRecord::Base.lease_connection
    connection.execute("SAVEPOINT without_schema")
    connection.execute("ALTER TABLE auction_houses RENAME TO auction_houses_hidden")

    get root_path

    assert_response :service_unavailable
    assert_select "h1", "Just a moment"
  ensure
    connection.execute("ROLLBACK TO SAVEPOINT without_schema")
  end

  test "the home page says when nothing was fetched yet" do
    get root_path

    assert_response :success
    assert_select ".empty-state", /fetcher/
  end

  test "the home page lists the markets being followed, not every known realm" do
    seed_item
    create_market(connected_realm_id: 77, name: "Never fetched")
    create_commodities

    get root_path

    assert_response :success
    assert_select "h2", "EU"
    assert_select "a.market-card[href=?]", market_path(@market)
    assert_select "a.market-card", /Commodities/
    assert_select "a.market-card", { text: /Never fetched/, count: 0 }
    assert_select ".market-card-meta", /42/
  end

  test "a returning player goes straight to their market" do
    seed_item

    get market_path(@market)
    get root_path

    assert_redirected_to market_path(@market)
  end

  test "browsing the commodities of a region does not change the realm remembered" do
    seed_item
    commodities = create_commodities

    get market_path(@market)
    get market_path(commodities)
    get root_path

    assert_redirected_to market_path(@market)
  end

  test "a player without a realm is remembered on the commodities" do
    commodities = create_commodities

    get market_path(commodities)
    get root_path

    assert_redirected_to market_path(commodities)
  end

  test "a remembered market that is gone is forgotten" do
    seed_item
    cookies[:market] = "0"

    get root_path

    assert_response :success
  end

  test "the list of markets stays reachable for a returning player" do
    seed_item

    get market_path(@market)
    get markets_path

    assert_response :success
    assert_select "a.market-card[href=?]", market_path(@market)
  end

  test "a market page lists what is on sale" do
    seed_item

    get market_path(@market)

    assert_response :success
    assert_select "h1", "Archimonde / Naxxramas"
    assert_select "a.product-link[href=?]", market_item_path(@market, 2589), "Linen Cloth"
    assert_select "img.icon[src=?]", "https://render.example/2589.jpg"
    assert_select "td .money[aria-label=?]", "12g 34s 56c"
    assert_select "td .change.up", "↗ +23.5%"
    assert_select ".listing-summary strong", "1"
  end

  test "a market page offers its realm and the commodities of its region" do
    seed_item
    commodities = create_commodities

    get market_path(@market)

    assert_select ".tabs a.is-selected[href=?]", market_path(@market)
    assert_select ".tabs a[href=?]", market_path(commodities), "Commodities"
  end

  test "a market page keeps the filters and the sort in its links" do
    seed_item

    get market_path(@market), params: { q: "linen", item_class: "Tradeskill", sort: "name", dir: "desc" }

    assert_response :success
    assert_select "a.is-sorted", /Product/
    assert_select "input[name=sort][value=name]"
    assert_select "input[name=dir][value=desc]"
    assert_select "input[name=q][value=linen]"
    assert_select "select[name=item_class] option[selected]", "Tradeskill"
    assert_select "th a[href*=?]", "item_class=Tradeskill"
    assert_select ".link-quiet", "Clear filters"
  end

  test "clicking the current sort reverses it" do
    seed_item

    get market_path(@market), params: { sort: "name" }

    assert_select "a.is-sorted[href*=?]", "dir=desc"
  end

  test "a filter without a match says so and offers to clear" do
    seed_item

    get market_path(@market), params: { q: "nonexistent" }

    assert_select ".empty-state", /No results/
    assert_select ".link-quiet", "Clear filters"
  end

  test "before a day of history, a market page explains why there is no trend" do
    create_item(2589)
    create_snapshot(@market, NOW)
    create_price(@market, 2589, NOW)

    get market_path(@market)

    assert_select ".mover-note", /after a day of snapshots/
  end

  test "a market page shows what moved" do
    create_item(2589, name: "Linen Cloth")
    create_snapshot(@market, NOW)
    create_snapshot(@market, NOW - 1.day)
    create_price(@market, 2589, NOW - 1.day, median: 100, auctions: MarketMovers::MIN_AUCTIONS)
    create_price(@market, 2589, NOW, median: 200, auctions: MarketMovers::MIN_AUCTIONS)
    create_sale(@market, 2589, NOW, value: 500)

    get market_path(@market)

    assert_select ".mover-card h2", "Biggest rises"
    assert_select ".mover .mover-name", "Linen Cloth"
  end

  test "a market page without snapshots says so" do
    get market_path(@market)

    assert_response :success
    assert_select ".empty-state", /No snapshot yet/
  end

  test "an unknown market is not found" do
    get market_path(0)

    assert_response :not_found
  end

  test "old data is flagged as such" do
    seed_item

    travel_to NOW + 1.hour do
      get market_path(@market)
      assert_select ".freshness.fresh", /ago/
    end

    travel_to NOW + 1.day do
      get market_path(@market)
      assert_select ".freshness.stale", /Stale data/
    end
  end

  test "an item page draws its curves, its sales and their tables" do
    seed_item

    get market_item_path(@market, 2589)

    assert_response :success
    assert_select "h1", "Linen Cloth"
    assert_select "[data-chart=line]", 2
    assert_select "[data-chart=columns]", 1
    assert_select "path.line.series-1"
    assert_select "path.line.series-2"
    assert_select "path.area"
    assert_select ".bar"
    assert_select "details.chart-data table", 3
    assert_select ".summary-price .money[aria-label=?]", "12g 34s 56c"
    assert_select ".summary-changes .change.up", "↗ +23.5%"
    assert_select ".price-range"
    assert_select "a[href=?]", "https://www.wowhead.com/item=2589"
  end

  test "an item page says what is plotted when an item is not on sale anymore" do
    create_item(2589)
    create_snapshot(@market, NOW)
    create_price(@market, 2589, NOW - 2.hours)

    get market_item_path(@market, 2589)

    assert_response :success
    assert_select ".note", /No listings in the latest snapshot/
    assert_select ".summary-price", "—"
  end

  test "a caged pet shows its species, without a list of variants" do
    create_item(82800, name: "Pet Cage", quality: "RARE")
    create_pet(39, name: "Mechanical Squirrel")
    create_pet(40, name: "Cat")
    create_snapshot(@market, NOW)
    create_price(@market, 82800, NOW, median: 100, variant: "pet:39")
    create_price(@market, 82800, NOW, median: 200, variant: "pet:40")

    get market_item_path(@market, 82800, variant: "pet:40")

    assert_response :success
    assert_select "h1", "Cat"
    assert_select ".variant-menu", false
    assert_select "a[href=?]", "https://www.wowhead.com/battle-pet/40"
  end

  test "gear opens on its most listed variant, and offers the others" do
    create_item(200000, name: "Test Sword", quality: "EPIC")
    create_snapshot(@market, NOW)
    create_price(@market, 200000, NOW, median: 100, quantity: 1, variant: "bonus:1")
    create_price(@market, 200000, NOW, median: 200, quantity: 9, variant: "bonus:2")

    get market_item_path(@market, 200000)

    assert_response :success
    assert_select ".summary-price .money[aria-label=?]", "2s"
    assert_select ".variant-menu summary", /Bonus 2/
    assert_select ".variant-menu a[href=?]", market_item_path(@market, 200000, variant: "bonus:1", period: "7d")
  end

  test "an item page shows the selected period" do
    seed_item

    get market_item_path(@market, 2589), params: { period: "30d" }

    assert_select ".segmented a.is-selected", "30d"
  end

  test "parameters of an unexpected shape do not break the pages" do
    seed_item

    get market_path(@market), params: { q: [ "x" ], sort: { a: "b" }, page: [ "2" ], item_class: [ "y" ], quality: { a: "b" } }
    assert_response :success

    get market_item_path(@market, 2589), params: { variant: [ "x" ], period: { a: "b" } }
    assert_response :success

    get market_item_path(@market, 2589), params: { variant: "a\0b" }
    assert_response :success

    get search_path, params: { q: [ "x" ], fragment: "1" }
    assert_response :success
  end

  test "an unknown period falls back to the default" do
    seed_item

    get market_item_path(@market, 2589), params: { period: "<script>" }

    assert_response :success
    assert_select ".segmented a.is-selected", ItemHistory::DEFAULT_PERIOD
  end

  test "an item page without data says so" do
    create_item(2589)

    get market_item_path(@market, 2589)

    assert_response :success
    assert_select ".empty-state", /Nothing in this period/
  end

  test "an unknown item is not found" do
    get market_item_path(@market, 123)

    assert_response :not_found
  end

  test "an item the API does not know still has a page" do
    Item.insert_all!([ { id: 999999 } ])
    create_snapshot(@market, NOW)
    create_price(@market, 999999, NOW)

    get market_item_path(@market, 999999)

    assert_response :success
    assert_select "h1", "Item #999999"
  end

  test "the search box suggests what is on sale on the player's markets" do
    seed_item
    get market_path(@market)

    get search_path, params: { q: "linen", fragment: "1" }

    assert_response :success
    assert_select "a.result[href=?]", market_item_path(@market, 2589)
    assert_select ".result-name", "Linen Cloth"
    assert_no_match "<html", response.body
  end

  test "without script, a search is a page of its own" do
    seed_item

    get search_path, params: { q: "linen" }

    assert_response :success
    assert_select "html"
    assert_select "a.result[href=?]", market_item_path(@market, 2589)
  end

  test "a search says when nothing matches, or when it is too short" do
    seed_item

    get search_path, params: { q: "nonexistent", fragment: "1" }
    assert_select ".search-hint", /Nothing for sale/

    get search_path, params: { q: "e", fragment: "1" }
    assert_select ".search-hint", /at least/
  end

  test "names coming from the API are escaped everywhere" do
    name = %(<script>alert("x")</script>)
    create_item(1, name: name)
    create_snapshot(@market, NOW)
    create_price(@market, 1, NOW)

    get market_path(@market)
    assert_no_match "<script>alert", response.body

    get market_item_path(@market, 1)
    assert_no_match "<script>alert", response.body
    assert_select "h1", name

    get search_path, params: { q: "script", fragment: "1" }
    assert_no_match "<script>alert", response.body
  end

  test "a market page links to its deals, which explain why there are none at first" do
    seed_item

    get market_path(@market)
    assert_select ".tabs a[href=?]", deals_market_path(@market), "Deals"

    get deals_market_path(@market)
    assert_response :success
    assert_select ".tabs a.is-selected", "Deals"
    assert_select ".empty-state", /Not enough history yet/
  end

  test "the deals page shows what to buy, and what is left after the cut" do
    seed_item
    ListedProduct.where(item_id: 2589).update_all(
      min_price: 100_000, usual_min_price: 200_000, usual_min_points: ListedProduct::MIN_USUAL_POINTS
    )

    get deals_market_path(@market)

    assert_response :success
    assert_select "a.product-link[href=?]", market_item_path(@market, 2589), "Linen Cloth"
    assert_select ".money[aria-label=?]", "10g"
    assert_select ".money[aria-label=?]", "20g"
    assert_select ".money[aria-label=?]", "9g"
    assert_select ".deal-discount", "50%"
    assert_select "th a.is-sorted", /Resale profit/

    get deals_market_path(@market), params: { sort: "discount" }
    assert_select "th a.is-sorted", /Below usual/
  end

  test "deals say so when nothing is below its usual price" do
    seed_item
    ListedProduct.where(item_id: 2589).update_all(
      min_price: 100_000, usual_min_price: 100_000, usual_min_points: ListedProduct::MIN_USUAL_POINTS
    )

    get deals_market_path(@market)

    assert_select ".empty-state", /No deals right now/
  end

  test "deals of an unknown market are not found" do
    get deals_market_path(0)

    assert_response :not_found
  end

  test "an item page gives its usual price and the margin of reselling at it" do
    seed_item
    ListedProduct.where(item_id: 2589).update_all(
      min_price: 100_000, usual_min_price: 200_000, usual_min_points: ListedProduct::MIN_USUAL_POINTS
    )

    get market_item_path(@market, 2589)

    assert_select ".summary-facts dt", /Usual minimum/
    assert_select ".summary-facts .money[aria-label=?]", "20g"
    assert_select ".summary-facts .money[aria-label=?]", "9g"
  end

  test "without enough history, an item page has no usual price to give" do
    seed_item

    get market_item_path(@market, 2589)

    assert_response :success
    assert_select ".summary-facts dt", /Usual minimum/
    assert_select ".summary-facts dd", "—"
  end

  test "watching a product adds it to the watchlist, and pressing again removes it" do
    seed_item

    get watchlist_path
    assert_select ".empty-state", /Nothing here yet/
    assert_select ".header-link small", false

    patch watchlist_path, params: { market_id: @market.id, item_id: 2589, series: "" }
    assert_redirected_to watchlist_path

    follow_redirect!
    assert_select "a.product-link[href=?]", market_item_path(@market, 2589), "Linen Cloth"
    assert_select ".header-link small", "1"

    get market_item_path(@market, 2589)
    assert_select ".watch-button.is-watching"

    patch watchlist_path, params: { market_id: @market.id, item_id: 2589, series: "" }
    follow_redirect!
    assert_select ".empty-state", /Nothing here yet/
  end

  test "watching goes back to the page it came from" do
    seed_item
    page = market_item_path(@market, 2589)

    patch watchlist_path, params: { market_id: @market.id, item_id: 2589, series: "" },
      headers: { "HTTP_REFERER" => "http://www.example.com#{page}" }

    assert_response :see_other
    assert_redirected_to page
  end

  test "a watched product no longer on sale is counted, not lost" do
    create_snapshot(@market, NOW)
    create_item(2589)
    cookies[:watchlist] = "#{@market.id}.2589"

    get watchlist_path

    assert_response :success
    assert_select ".note", /1 product you follow has no listing/
  end

  test "a watchlist cookie that makes no sense does not break the pages" do
    seed_item
    cookies[:watchlist] = "'; DROP TABLE items; --_99999999999.1_.."

    get watchlist_path
    assert_response :success

    get market_path(@market)
    assert_response :success
  end

  test "an item page compares the product to the other markets of its region" do
    seed_item
    other = create_market(connected_realm_id: 1302, name: "Archimonde")
    create_snapshot(other, NOW)
    create_price(other, 2589, NOW, min: 30_000)

    get market_item_path(@market, 2589)

    assert_select ".across-markets a.product-link[href=?]", market_item_path(other, 2589), "Archimonde"
    assert_select ".across-markets tr.is-current", /Archimonde \/ Naxxramas/
  end

  test "an item page has no comparison on a single market" do
    seed_item

    get market_item_path(@market, 2589)

    assert_select ".across-markets", false
  end

  test "an item's prices can be downloaded, in copper and UTC" do
    seed_item

    get market_item_path(@market, 2589, period: "30d", format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match "archimonde-naxxramas-2589-30d.csv", response.headers["Content-Disposition"]
    lines = response.body.lines(chomp: true)
    assert_equal "time,median_price,min_price,p25_price,p75_price,quantity,listings,daily", lines.first
    assert_equal "2026-11-05T12:00:00Z,123456,61728,123446,123466,5,1,false", lines.last
    assert_equal 3, lines.size
  end

  test "an item page links to its download, for the period shown" do
    seed_item

    get market_item_path(@market, 2589), params: { period: "30d" }

    assert_select "a.csv-link[href=?]", market_item_path(@market, 2589, period: "30d", format: :csv)
  end

  test "an unknown format is refused" do
    seed_item

    get market_item_path(@market, 2589, format: :xml)

    assert_response :not_acceptable
  end

  test "text typed in a search is escaped" do
    seed_item

    get search_path, params: { q: "<script>alert(1)</script>" }

    assert_no_match "<script>alert", response.body
  end
end
