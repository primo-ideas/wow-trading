require "test_helper"

class PagesTest < ActionDispatch::IntegrationTest
  include RealmsHelper

  setup do
    @market = create_market(name: "Archimonde / Naxxramas")
    @realm = create_realm(@market, name: "Archimonde")
    @connected = create_realm(@market, name: "Naxxramas")
  end

  def seed_item
    create_item(2589, name: "Linen Cloth", icon_url: "https://render.example/2589.jpg")
    create_snapshot(@market, NOW, auction_count: 42)
    create_snapshot(@market, NOW - 1.day)
    create_price(@market, 2589, NOW, median: 123_456)
    create_price(@market, 2589, NOW - 1.day, median: 100_000)
    create_sale(@market, 2589, NOW, quantity: 3, value: 30_000)
  end

  def seed_commodity
    commodities = create_commodities
    create_snapshot(commodities, NOW)
    create_item(2770, name: "Copper Ore", item_class: "Tradeskill", item_subclass: "Metal & Stone")
    create_price(commodities, 2770, NOW, median: 5_000)
    commodities
  end

  def home(realm = @realm, **options) = realm_home_path(realm, **options)

  def item_page(id, realm = @realm, **options) = item_on_realm_path(realm, id, **options)

  def deals_page(realm = @realm, **options) = realm_deals_path(realm.region, realm.slug, options)

  def search_page(realm = @realm, **options) = realm_search_path(realm.region, realm.slug, options)

  def tooltip_page(id, realm = @realm, variant: nil) = item_tooltip_path(realm, id, variant)

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

  # Realms

  test "the home page says when nothing was fetched yet" do
    get root_path

    assert_response :success
    assert_select ".empty-state", /fetcher/
  end

  test "the home page offers the realms being followed, one by one, not every known realm" do
    seed_item
    create_realm(create_market(connected_realm_id: 77, name: "Never fetched"), name: "Ghost")

    get root_path

    assert_response :success
    assert_select "input[role=combobox][aria-controls=realm-suggestions]"
    assert_select ".realm-region h2", "Europe"
    assert_select ".realm-list a[href=?]", home, "Archimonde"
    assert_select ".realm-list a[href=?]", home(@connected), "Naxxramas"
    assert_select ".realm-list a", { text: "Ghost", count: 0 }
  end

  test "where the commodities of a region are followed, so is every realm of it" do
    seed_commodity
    ghost = create_realm(create_market(connected_realm_id: 77, name: "Never fetched"), name: "Ghost")

    get root_path

    assert_select ".realm-list a[href=?]", home(ghost), "Ghost"

    get home(ghost)

    assert_response :success
    assert_select ".note", /Only reagents, consumables/
    assert_select "a.product-link", "Copper Ore"
  end

  test "players never see markets: neither connected realms put together, nor commodities" do
    seed_item
    seed_commodity

    [ root_path, home, deals_page, item_page(2589), item_page(2770), search_page(q: "o") ].each do |page|
      get page
      assert_response :success
      assert_no_match "Archimonde / Naxxramas", response.body, page
      assert_no_match(/commodit/i, response.body, page)
    end
  end

  test "a returning player goes straight to their realm" do
    seed_item

    get home(@connected)
    get root_path

    assert_redirected_to home(@connected)
  end

  test "a remembered realm that is gone is forgotten" do
    seed_item
    cookies[:realm] = "eu/nowhere"

    get root_path

    assert_response :success
    assert_select ".realm-picker"
  end

  test "the list of realms stays reachable for a returning player, and leads back to theirs" do
    seed_item

    get home
    get realms_path

    assert_response :success
    assert_select ".picker-current a[href=?]", home, /Archimonde/
  end

  test "without script, the realm picker finds realms by name, whatever the accents" do
    seed_item
    stormes = create_realm(@market, name: "Festung der Stürme", slug: "festung-der-stürme")

    get realms_path, params: { q: "sturme" }

    assert_response :success
    assert_select ".realm-directory[open]"
    assert_select ".realm-list li:not([hidden]) a", "Festung der Stürme"
    assert_select ".realm-list li[hidden] a", "Archimonde"
    assert_select ".realm-list a[href=?]", home(stormes)

    get home(stormes)
    assert_response :success
    assert_select "h1", "Festung der Stürme"
  end

  test "picking a realm for an item leads to its page there" do
    seed_item

    get realms_path, params: { item: 2589 }

    assert_select ".lead", /Linen Cloth/
    assert_select ".realm-list a[href=?]", item_page(2589, @connected), "Naxxramas"
  end

  test "an item page offers to change realm and come back to the same item" do
    seed_item

    get item_page(2589)

    assert_select ".realm-button[href=?]", realms_path(item: 2589), /Archimonde/
  end

  test "a realm page leads with an item search, and lists its realm and region goods together" do
    seed_item
    seed_commodity

    get home

    assert_response :success
    assert_select "h1", "Archimonde"
    assert_select ".page-search input[role=combobox][autofocus]"
    assert_select ".site-search", false
    assert_select "a.product-link[href=?]", item_page(2589), "Linen Cloth"
    assert_select "a.product-link[href=?]", item_page(2770), "Copper Ore"
    assert_select "a.product-link[data-tooltip=?]", tooltip_page(2589)
    assert_select "img.icon[src=?]", "https://render.example/2589.jpg"
    assert_select "td .money[aria-label=?]", "12g 34s 56c"
    assert_select "td .change.up", "↗ +23.5%"
    assert_select ".listing-summary strong", "2"
  end

  test "a connected realm shows the same prices under its own name" do
    seed_item

    get home(@connected)

    assert_select "h1", "Naxxramas"
    assert_select "a.product-link[href=?]", item_page(2589, @connected), "Linen Cloth"
  end

  test "a realm page explains its figures" do
    seed_item

    get home

    assert_select "th a[data-tip]", /Median/
    assert_select "th a[data-tip=?]", TermsHelper::TERMS[:sold]
  end

  test "a realm page keeps the filters and the sort in its links" do
    seed_item

    get home, params: { q: "linen", item_class: "Tradeskill", sort: "name", dir: "desc" }

    assert_response :success
    assert_select "a.is-sorted", /Product/
    assert_select "input[name=sort][value=name]"
    assert_select "input[name=dir][value=desc]"
    assert_select "input[name=q][value=linen]"
    assert_select "select[name=item_class] option[selected]", "Tradeskill"
    assert_select "th a[href*=?]", "item_class=Tradeskill"
    assert_select "th a[href^=?]", home
    assert_select ".link-quiet", "Clear filters"
  end

  test "clicking the current sort reverses it" do
    seed_item

    get home, params: { sort: "name" }

    assert_select "a.is-sorted[href*=?]", "dir=desc"
  end

  test "a filter without a match says so and offers to clear" do
    seed_item

    get home, params: { q: "nonexistent" }

    assert_select ".empty-state", /No results/
    assert_select ".link-quiet", "Clear filters"
  end

  test "before a day of history, a realm page explains why there is no trend" do
    create_item(2589)
    create_snapshot(@market, NOW)
    create_price(@market, 2589, NOW)

    get home

    assert_select ".mover-note", /after a day of snapshots/
  end

  test "a realm page shows what moved" do
    create_item(2589, name: "Linen Cloth")
    create_snapshot(@market, NOW)
    create_snapshot(@market, NOW - 1.day)
    create_price(@market, 2589, NOW - 1.day, median: 100, auctions: MarketMovers::MIN_AUCTIONS)
    create_price(@market, 2589, NOW, median: 200, auctions: MarketMovers::MIN_AUCTIONS)
    create_sale(@market, 2589, NOW, value: 500)

    get home

    assert_select ".mover-card h2", "Biggest rises"
    assert_select ".mover[href=?] .mover-name", item_page(2589), "Linen Cloth"
    assert_select ".mover[data-tooltip=?]", tooltip_page(2589)
  end

  test "a realm page without snapshots says so" do
    get home

    assert_response :success
    assert_select ".empty-state", /No prices yet/
  end

  test "an unknown realm is not found" do
    get realm_path("eu", "nowhere")
    assert_response :not_found

    get "/xx/archimonde"
    assert_response :not_found
  end

  test "old data is flagged as such" do
    seed_item

    travel_to NOW + 1.hour do
      get home
      assert_select ".freshness.fresh", /ago/
    end

    travel_to NOW + 1.day do
      get home
      assert_select ".freshness.stale", /Stale data/
    end
  end

  test "a realm is as fresh as the market of it that lags behind" do
    seed_item
    commodities = create_commodities
    create_snapshot(commodities, NOW - 1.day)

    travel_to NOW + 1.hour do
      get home
      assert_select ".freshness.stale", /Stale data/
    end
  end

  # Items

  test "an item page draws its curves, its sales and their tables" do
    seed_item

    get item_page(2589)

    assert_response :success
    assert_select ".breadcrumb a[href=?]", home, "Archimonde"
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

  test "an item of the region's commodities has its page on the realm" do
    seed_item
    seed_commodity

    get item_page(2770)

    assert_response :success
    assert_select "h1", "Copper Ore"
    assert_select ".summary-price .money[aria-label=?]", "50s"
  end

  test "an item page says what is plotted when an item is not on sale anymore" do
    create_item(2589)
    create_snapshot(@market, NOW)
    create_price(@market, 2589, NOW - 2.hours)

    get item_page(2589)

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

    get item_page(82800, variant: "pet:40")

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

    get item_page(200000)

    assert_response :success
    assert_select ".summary-price .money[aria-label=?]", "2s"
    assert_select ".variant-menu summary", /Bonus 2/
    assert_select ".variant-menu a[href=?]", item_page(200000, variant: "bonus:1", period: "7d")
  end

  test "an item page shows the selected period" do
    seed_item

    get item_page(2589), params: { period: "30d" }

    assert_select ".segmented a.is-selected[href=?]", item_page(2589, period: "30d"), "30d"
  end

  test "an item page explains its figures" do
    seed_item

    get item_page(2589)

    assert_select ".summary-facts dt[data-tip=?]", TermsHelper::TERMS[:usual], /Usual minimum/
  end

  test "parameters of an unexpected shape do not break the pages" do
    seed_item

    get home, params: { q: [ "x" ], sort: { a: "b" }, page: [ "2" ], item_class: [ "y" ], quality: { a: "b" } }
    assert_response :success

    get item_page(2589), params: { variant: [ "x" ], period: { a: "b" } }
    assert_response :success

    get item_page(2589), params: { variant: "a\0b" }
    assert_response :success

    get search_page, params: { q: [ "x" ], fragment: "1" }
    assert_response :success

    get realms_path, params: { q: { a: "b" }, item: [ "1" ], variant: "a\0b" }
    assert_response :success

    get tooltip_page(2589), params: { variant: [ "x" ] }
    assert_response :success
  end

  test "an unknown period falls back to the default" do
    seed_item

    get item_page(2589), params: { period: "<script>" }

    assert_response :success
    assert_select ".segmented a.is-selected", ItemHistory::DEFAULT_PERIOD
  end

  test "an item page without data says so" do
    create_item(2589)

    get item_page(2589)

    assert_response :success
    assert_select ".empty-state", /Nothing in this period/
  end

  test "an unknown item is not found" do
    get item_page(123)

    assert_response :not_found
  end

  test "an item the API does not know still has a page" do
    Item.insert_all!([ { id: 999999 } ])
    create_snapshot(@market, NOW)
    create_price(@market, 999999, NOW)

    get item_page(999999)

    assert_response :success
    assert_select "h1", "Item #999999"
  end

  # Tooltips

  test "hovering a product shows what it is and where its price stands on the realm" do
    create_item(2589, name: "Linen Cloth", quality: "COMMON", item_class: "Tradeskill", item_subclass: "Cloth")
    create_snapshot(@market, NOW)
    create_price(@market, 2589, NOW, median: 123_456, min: 100_000, quantity: 7)

    get tooltip_page(2589)

    assert_response :success
    assert_no_match "<html", response.body
    assert_select ".item-tip-head strong.q-common", "Linen Cloth"
    assert_select ".item-tip-kind", "Common · Tradeskill · Cloth"
    assert_select ".item-tip-facts .money[aria-label=?]", "10g"
    assert_select ".item-tip-facts dd", "7"
    assert_select ".item-tip-where", /On Archimonde/
  end

  test "a product card says when nothing is for sale, and looking does not change realm" do
    create_item(2589)
    get home(@connected)

    get tooltip_page(2589)

    assert_select ".item-tip-where", /Not for sale on Archimonde/
    get root_path
    assert_redirected_to home(@connected)
  end

  test "a caged pet's card is its species'" do
    create_item(82800, name: "Pet Cage", quality: "RARE")
    create_pet(39, name: "Mechanical Squirrel")
    create_snapshot(@market, NOW)
    create_price(@market, 82800, NOW, variant: "pet:39")

    get tooltip_page(82800, variant: "pet:39")

    assert_select ".item-tip-head strong", "Mechanical Squirrel"
    assert_select ".item-tip-kind", "Rare · Battle pet"
  end

  # Search

  test "the search box suggests what is on sale on the realm, its region's goods included" do
    seed_item
    seed_commodity

    get search_page, params: { q: "copper", fragment: "1" }

    assert_response :success
    assert_select "a.result[href=?]", item_page(2770)
    assert_select "a.result[data-tooltip=?]", tooltip_page(2770)
    assert_select ".result-name", "Copper Ore"
    assert_select ".result-kind", "Metal & Stone"
    assert_no_match "<html", response.body
  end

  test "searching on a realm makes it the player's" do
    seed_item

    get search_page(@connected), params: { q: "linen", fragment: "1" }

    assert_select "a.result[href=?]", item_page(2589, @connected)
    get root_path
    assert_redirected_to home(@connected)
  end

  test "without script, a search is a page of its own" do
    seed_item

    get search_page, params: { q: "linen" }

    assert_response :success
    assert_select "html"
    assert_select "a.result[href=?]", item_page(2589)
  end

  test "a search says when nothing matches, or when it is too short" do
    seed_item

    get search_page, params: { q: "nonexistent", fragment: "1" }
    assert_select ".search-hint", /Nothing for sale on Archimonde/

    get search_page, params: { q: "e", fragment: "1" }
    assert_select ".search-hint", /at least/
  end

  test "pages other than a realm's own search from the header" do
    seed_item

    get item_page(2589)

    assert_select "form.site-search[action=?] input[role=combobox]", search_page
  end

  test "before a realm is picked, there is nothing to search" do
    seed_item

    get root_path

    assert_select ".site-search", false
    assert_select ".realm-button", false
  end

  test "names coming from the API are escaped everywhere" do
    name = %(<script>alert("x")</script>)
    create_item(1, name: name)
    create_snapshot(@market, NOW)
    create_price(@market, 1, NOW)

    get home
    assert_no_match "<script>alert", response.body

    get item_page(1)
    assert_no_match "<script>alert", response.body
    assert_select "h1", name

    get search_page, params: { q: "script", fragment: "1" }
    assert_no_match "<script>alert", response.body

    get tooltip_page(1)
    assert_no_match "<script>alert", response.body
  end

  test "realm names are escaped too" do
    seed_item
    create_realm(@market, name: %(<img src=x onerror=alert(1)>), slug: "evil")

    get realms_path
    assert_no_match "<img src=x", response.body

    get realm_path("eu", "evil")
    assert_no_match "<img src=x", response.body
  end

  test "text typed in a search is escaped" do
    seed_item

    get search_page, params: { q: "<script>alert(1)</script>" }
    assert_no_match "<script>alert", response.body

    get realms_path, params: { q: "<script>alert(1)</script>" }
    assert_no_match "<script>alert", response.body
  end

  # Deals

  test "a realm page links to its deals, which explain why there are none at first" do
    seed_item

    get home
    assert_select ".tabs a[href=?]", deals_page, "Deals"

    get deals_page
    assert_response :success
    assert_select ".tabs a.is-selected", "Deals"
    assert_select ".empty-state", /Not enough history yet/
  end

  test "the deals page shows what to buy, and what is left after the cut" do
    seed_item
    ListedProduct.where(item_id: 2589).update_all(
      min_price: 100_000, usual_min_price: 200_000, usual_min_points: ListedProduct::MIN_USUAL_POINTS
    )

    get deals_page

    assert_response :success
    assert_select "a.product-link[href=?]", item_page(2589), "Linen Cloth"
    assert_select ".money[aria-label=?]", "10g"
    assert_select ".money[aria-label=?]", "20g"
    assert_select ".money[aria-label=?]", "9g"
    assert_select ".deal-discount", "50%"
    assert_select "th a.is-sorted", /Resale profit/

    get deals_page, params: { sort: "discount" }
    assert_select "th a.is-sorted", /Below usual/
  end

  test "deals take in the goods of the region" do
    seed_item
    seed_commodity
    ListedProduct.where(item_id: 2770).update_all(
      min_price: 100_000, usual_min_price: 200_000, usual_min_points: ListedProduct::MIN_USUAL_POINTS
    )

    get deals_page

    assert_select "a.product-link[href=?]", item_page(2770), "Copper Ore"
  end

  test "deals say so when nothing is below its usual price" do
    seed_item
    ListedProduct.where(item_id: 2589).update_all(
      min_price: 100_000, usual_min_price: 100_000, usual_min_points: ListedProduct::MIN_USUAL_POINTS
    )

    get deals_page

    assert_select ".empty-state", /No deals right now/
  end

  test "deals of an unknown realm are not found" do
    get realm_deals_path("eu", "nowhere")

    assert_response :not_found
  end

  test "an item page gives its usual price and the margin of reselling at it" do
    seed_item
    ListedProduct.where(item_id: 2589).update_all(
      min_price: 100_000, usual_min_price: 200_000, usual_min_points: ListedProduct::MIN_USUAL_POINTS
    )

    get item_page(2589)

    assert_select ".summary-facts dt", /Usual minimum/
    assert_select ".summary-facts .money[aria-label=?]", "20g"
    assert_select ".summary-facts .money[aria-label=?]", "9g"
  end

  test "without enough history, an item page has no usual price to give" do
    seed_item

    get item_page(2589)

    assert_response :success
    assert_select ".summary-facts dt", /Usual minimum/
    assert_select ".summary-facts dd", "—"
  end

  # Watchlist

  test "watching a product adds it to the watchlist, and pressing again removes it" do
    seed_item
    get home

    get watchlist_path
    assert_select ".empty-state", /Nothing here yet/
    assert_select ".header-link small", false

    patch watchlist_path, params: { item_id: 2589, series: "" }
    assert_redirected_to watchlist_path

    follow_redirect!
    assert_select "a.product-link[href=?]", item_page(2589), "Linen Cloth"
    assert_select ".header-link small", "1"

    get item_page(2589)
    assert_select ".watch-button.is-watching"

    patch watchlist_path, params: { item_id: 2589, series: "" }
    follow_redirect!
    assert_select ".empty-state", /Nothing here yet/
  end

  test "the watchlist shows prices on whatever realm the player is on" do
    seed_item
    hyjal = create_market(connected_realm_id: 1302, name: "Hyjal")
    hyjal_realm = create_realm(hyjal, name: "Hyjal")
    create_snapshot(hyjal, NOW)
    create_price(hyjal, 2589, NOW, median: 50_000)
    patch watchlist_path, params: { item_id: 2589, series: "" }

    get home
    get watchlist_path
    assert_select "td .money[aria-label=?]", "12g 34s 56c"

    get home(hyjal_realm)
    get watchlist_path
    assert_select "a.product-link[href=?]", item_page(2589, hyjal_realm)
    assert_select "td .money[aria-label=?]", "5g"
  end

  test "without a realm, the watchlist asks for one" do
    seed_item
    patch watchlist_path, params: { item_id: 2589, series: "" }

    get watchlist_path

    assert_select ".empty-state a[href=?]", realms_path, "Choose yours"
  end

  test "watching goes back to the page it came from" do
    seed_item
    page = item_page(2589)

    patch watchlist_path, params: { item_id: 2589, series: "" },
      headers: { "HTTP_REFERER" => "http://www.example.com#{page}" }

    assert_response :see_other
    assert_redirected_to page
  end

  test "a watched product no longer on sale is counted, not lost" do
    create_snapshot(@market, NOW)
    create_item(2589)
    cookies[:watched] = "2589"
    get home

    get watchlist_path

    assert_response :success
    assert_select ".note", /1 product you follow has no listing on Archimonde/
  end

  test "products watched market by market are still watched" do
    seed_item
    cookies[:watchlist] = "#{@market.id}.2589"
    get home

    get watchlist_path

    assert_select "a.product-link", "Linen Cloth"
  end

  test "a watchlist cookie that makes no sense does not break the pages" do
    seed_item
    cookies[:watched] = "'; DROP TABLE items; --_99999999999.1_.."

    get home
    assert_response :success

    get watchlist_path
    assert_response :success
  end

  # Target prices

  test "a target price set on an item page flags it once the cheapest listing reaches it" do
    seed_item
    get home

    patch watchlist_target_path, params: { item_id: 2589, series: "", target: "6g" },
      headers: { "HTTP_REFERER" => "http://www.example.com#{item_page(2589)}" }
    assert_redirected_to item_page(2589)
    follow_redirect!
    assert_select ".watch-button.is-watching"
    assert_select ".target-form input[name=target][value=?]", "6g"
    assert_select ".target-hit", false
    assert_select ".watch-hits", false

    patch watchlist_target_path, params: { item_id: 2589, series: "", target: "7g" }
    get item_page(2589)
    assert_select ".target-hit .money[aria-label=?]", "6g 17s 28c"
    assert_select ".header-link .watch-hits", "1 at target"

    get watchlist_path
    assert_select ".target-summary", /1 product/
    assert_select "tr.is-at-target .target-pill", "At target"
    assert_select "tr.is-at-target .target-form input[value=?]", "7g"
  end

  test "an empty target takes it off, and an amount that makes no sense changes nothing" do
    seed_item
    get home
    patch watchlist_target_path, params: { item_id: 2589, series: "", target: "7g" }

    patch watchlist_target_path, params: { item_id: 2589, series: "", target: "lots" }
    follow_redirect!
    assert_select ".flash", /is not an amount/
    assert_select "tr.is-at-target"

    patch watchlist_target_path, params: { item_id: 2589, series: "", target: "" }
    follow_redirect!
    assert_select "tr.is-at-target", false
    assert_select "a.product-link", "Linen Cloth"
  end

  test "a target set from the watchlist follows the product there" do
    seed_item
    get home
    patch watchlist_path, params: { item_id: 2589, series: "" }

    get watchlist_path

    assert_select "th", /Target/
    assert_select ".target-form input[name=target][value='']"
  end

  test "parameters of an unexpected shape do not break target prices" do
    seed_item

    patch watchlist_target_path, params: { item_id: [ "1" ], series: { a: "b" }, target: [ "5g" ] }
    assert_response :see_other
    patch watchlist_target_path, params: { item_id: "2589", series: "", target: "9" * 50 }
    assert_response :see_other

    get watchlist_path
    assert_response :success
  end

  # When it sells

  test "an item page shows when it sells, once there are a few days of sales" do
    create_item(2589, name: "Linen Cloth")
    (0..72).each { |hours| create_snapshot(@market, NOW - hours.hours) }
    create_price(@market, 2589, NOW)
    [ 0, 1, 2 ].each { |day| create_sale(@market, 2589, NOW - day.days, quantity: 4, value: 400) }

    get item_page(2589)

    assert_select ".rhythm h2", "When it sells"
    assert_select ".rhythm-head strong", "12:00"
    assert_select ".rhythm [data-chart=columns][data-chart-group=hours]"
    assert_select ".rhythm-wait", /a week of history/
    assert_select ".rhythm details.chart-data th", "Hour"
    assert_select "[data-chart=columns][data-chart-group=time]"
  end

  test "an item page says nothing of when it sells without sales" do
    seed_item
    SalesPoint.delete_all

    get item_page(2589)

    assert_select ".rhythm", false
  end

  # Recently viewed

  test "an item page hands the browser what to keep of it, and the realm page a place to show it" do
    seed_item

    get item_page(2589)
    recent = JSON.parse(css_select(".product-head").first["data-recent-item"])
    assert_equal({ "id" => 2589, "name" => "Linen Cloth", "icon" => "https://render.example/2589.jpg", "quality" => "q-common" }, recent)
    assert_select "form.site-search[data-items-path=?]", "#{home}/items/"

    get home
    assert_select ".recent-strip[hidden][data-items-path=?]", "#{home}/items/"
  end

  test "a caged pet is kept with its species" do
    create_item(82800, name: "Pet Cage", quality: "RARE")
    create_pet(39, name: "Mechanical Squirrel")
    create_snapshot(@market, NOW)
    create_price(@market, 82800, NOW, variant: "pet:39")

    get item_page(82800, variant: "pet:39")

    recent = JSON.parse(css_select(".product-head").first["data-recent-item"])
    assert_equal [ "pet:39", "Mechanical Squirrel" ], recent.values_at("variant", "name")
  end

  # Other realms

  test "an item page compares the product to the other realms of its region" do
    seed_item
    other = create_market(connected_realm_id: 1302, name: "Hyjal")
    hyjal = create_realm(other, name: "Hyjal")
    create_snapshot(other, NOW)
    create_price(other, 2589, NOW, min: 30_000)

    get item_page(2589)

    assert_select ".across-markets a.product-link[href=?]", item_page(2589, hyjal), "Hyjal"
    assert_select ".across-markets tr.is-current", /Archimonde/
    assert_select ".across-markets tr.is-current .connected[data-tip=?]", "Shares its auction house with Naxxramas.", "+ 1"
  end

  test "an item page has no comparison on a single market" do
    seed_item

    get item_page(2589)

    assert_select ".across-markets", false
  end

  # Downloads

  test "an item's prices can be downloaded, in copper and UTC" do
    seed_item

    get item_page(2589, period: "30d", format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match "eu-archimonde-2589-30d.csv", response.headers["Content-Disposition"]
    lines = response.body.lines(chomp: true)
    assert_equal "time,median_price,min_price,p25_price,p75_price,quantity,listings,daily", lines.first
    assert_equal "2026-11-05T12:00:00Z,123456,61728,123446,123466,5,1,false", lines.last
    assert_equal 3, lines.size
  end

  test "an item page links to its download, for the period shown" do
    seed_item

    get item_page(2589), params: { period: "30d" }

    assert_select "a.csv-link[href=?]", item_page(2589, period: "30d", format: :csv)
  end

  test "an unknown format is refused" do
    seed_item

    get item_page(2589, format: :xml)

    assert_response :not_acceptable
  end

  # Old addresses

  test "an old market address leads to a realm of it, the player's own if it is one" do
    seed_item

    get "/markets/#{@market.id}"
    assert_response :moved_permanently
    assert_redirected_to home

    get home(@connected)
    get "/markets/#{@market.id}/items/2589?variant=pet:39&period=30d"
    assert_redirected_to item_page(2589, @connected, variant: "pet:39", period: "30d")

    get "/markets/#{@market.id}/deals"
    assert_redirected_to deals_page(@connected)

    get "/markets/#{@market.id}/items/2589.csv"
    assert_redirected_to item_page(2589, @connected, format: :csv)
  end

  test "an old commodities address leads to the player's realm, or to picking one" do
    seed_item
    commodities = seed_commodity

    get "/markets/#{commodities.id}/items/2770"
    assert_redirected_to realms_path(item: 2770)

    get home
    get "/markets/#{commodities.id}/items/2770"
    assert_redirected_to item_page(2770)
  end

  test "old search and list addresses still lead somewhere" do
    seed_item

    get "/markets"
    assert_redirected_to realms_path

    get "/search?q=linen"
    assert_redirected_to realms_path

    get home
    get "/search?q=linen"
    assert_redirected_to search_page(q: "linen")

    get "/markets/0"
    assert_response :not_found
  end
end
