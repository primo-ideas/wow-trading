require "test_helper"

class PagesTest < ActionDispatch::IntegrationTest
  setup do
    @market = create_market(name: "Archimonde / Naxxramas")
  end

  def seed_item
    create_item(2589, name: "Étoffe de lin")
    create_snapshot(@market, NOW, auction_count: 42)
    create_snapshot(@market, NOW - 1.day)
    create_price(@market, 2589, NOW, median: 123_456)
    create_price(@market, 2589, NOW - 1.day, median: 100_000)
    create_sale(@market, 2589, NOW, quantity: 3, value: 30_000)
  end

  test "the health check answers" do
    get "/up"

    assert_response :success
  end

  test "the home page says when nothing was fetched yet" do
    AuctionHouse.where(id: @market.id).delete_all

    get root_path

    assert_response :success
    assert_select ".empty", /fetcher/
  end

  test "the home page lists markets by region with their latest snapshot" do
    seed_item
    create_market(region: "us", connected_realm_id: nil, name: "Commodities")

    get root_path

    assert_response :success
    assert_select "h2", "EU"
    assert_select "h2", "US"
    assert_select "a[href=?]", market_path(@market), "Archimonde / Naxxramas"
    assert_select "a", "Matières premières"
    assert_select "td", "42"
  end

  test "searching markets ignores case and accents, and keeps commodities" do
    other = create_market(connected_realm_id: 7, name: "Sargéras")
    commodities = create_market(connected_realm_id: nil, name: "Commodities")

    get root_path, params: { q: "sargeras" }

    assert_select "a[href=?]", market_path(other)
    assert_select "a[href=?]", market_path(commodities)
    assert_select "a[href=?]", market_path(@market), false
  end

  test "a market page lists what is on sale" do
    seed_item

    get market_path(@market)

    assert_response :success
    assert_select "h1", "Archimonde / Naxxramas"
    assert_select "a[href=?]", market_item_path(@market, 2589), "Étoffe de lin"
    assert_select "td", "12 po 34 pa 56 pc"
    assert_select "td", "↗ +23,5 %"
  end

  test "a market page keeps the search and the sort in its links" do
    seed_item

    get market_path(@market), params: { q: "etoffe", sort: "name" }

    assert_response :success
    assert_select "a.is-sorted", "Objet"
    assert_select "input[name=sort][value=name]"
    assert_select "input[name=q][value=etoffe]"
  end

  test "a market page without snapshots says so" do
    get market_path(@market)

    assert_response :success
    assert_select ".empty", /Aucun relevé/
  end

  test "an unknown market is not found" do
    get market_path(0)

    assert_response :not_found
  end

  test "an item page draws its curves, its sales and their tables" do
    seed_item

    get market_item_path(@market, 2589)

    assert_response :success
    assert_select "h1", "Étoffe de lin"
    assert_select "[data-chart=line]", 2
    assert_select "[data-chart=columns]", 1
    assert_select "path.line.series-1"
    assert_select "path.line.series-2"
    assert_select "path.area"
    assert_select "path.column"
    assert_select "details.chart-data table", 3
    assert_select ".tile-value", "12 po 34 pa 56 pc"
    assert_select ".tile-delta", /↗ \+23,5 %/
  end

  test "an item page says what is plotted when an item is not on sale anymore" do
    create_item(2589)
    create_snapshot(@market, NOW)
    create_price(@market, 2589, NOW - 2.hours)

    get market_item_path(@market, 2589)

    assert_response :success
    assert_select ".note", /Aucune annonce au dernier relevé/
    assert_select ".tile-value", "—"
  end

  test "an item with variants only opens on one of them, and links to the others" do
    create_item(82800, name: "Cage à mascotte")
    create_snapshot(@market, NOW)
    create_price(@market, 82800, NOW, median: 100, variant: "pet:39")
    create_price(@market, 82800, NOW, median: 200, variant: "pet:40")

    get market_item_path(@market, 82800)

    assert_response :success
    assert_select ".tile-value", "1 pa"
    assert_select "a.is-selected", "Espèce 39"
    assert_select "a[href=?]", market_item_path(@market, 82800, variant: "pet:40", period: "7j"), "Espèce 40"
  end

  test "an item page shows the selected period" do
    seed_item

    get market_item_path(@market, 2589), params: { period: "30j" }

    assert_select "a.is-selected", "30j"
  end

  test "parameters of an unexpected shape do not break the pages" do
    seed_item

    get market_path(@market), params: { q: [ "x" ], sort: { a: "b" }, page: [ "2" ] }
    assert_response :success

    get market_item_path(@market, 2589), params: { variant: [ "x" ], period: { a: "b" } }
    assert_response :success

    get market_item_path(@market, 2589), params: { variant: "a\0b" }
    assert_response :success
  end

  test "an unknown period falls back to the default" do
    seed_item

    get market_item_path(@market, 2589), params: { period: "<script>" }

    assert_response :success
    assert_select "a.is-selected", ItemHistory::DEFAULT_PERIOD
  end

  test "an item page without data says so" do
    create_item(2589)

    get market_item_path(@market, 2589)

    assert_response :success
    assert_select ".empty", /Aucune donnée/
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
    assert_select "h1", "Objet #999999"
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
  end
end
