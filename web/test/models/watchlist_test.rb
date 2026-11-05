require "test_helper"

class WatchlistTest < ActiveSupport::TestCase
  test "adds a product, and removes it the second time" do
    list = Watchlist.new(nil)

    list.toggle("2589", "")
    assert list.include?(2589, "")

    list.toggle("2589", "")
    assert_not list.include?(2589, "")
    assert list.empty?
  end

  test "survives the trip through its cookie, with its pets" do
    list = Watchlist.new(nil)
    list.toggle(2589, "")
    list.toggle(82800, "pet:39")

    restored = Watchlist.new(list.to_cookie)

    assert restored.include?(2589, "")
    assert restored.include?(82800, "pet:39")
    assert_not restored.include?(82800, "")
    assert_equal 2, restored.size
  end

  test "its cookie only holds characters that are not escaped" do
    list = Watchlist.new(nil)
    list.toggle(2589, "")
    list.toggle(82800, "pet:39")

    assert_equal list.to_cookie, CGI.escape(list.to_cookie)
  end

  test "reads the cookie of the time products were followed market by market" do
    list = Watchlist.new(nil, legacy: "60.2589_60.82800.39_61.2589")

    assert_equal [ Watchlist::Entry.new(2589, ""), Watchlist::Entry.new(82800, "pet:39") ], list.entries
  end

  test "once written, its own cookie wins over the old one" do
    list = Watchlist.new("", legacy: "60.2589")

    assert list.empty?
  end

  test "ignores whatever a cookie holds that it did not write" do
    list = Watchlist.new("2589_abc_1.2.3_;DROP_.5_7.")

    assert_equal [ Watchlist::Entry.new(2589, "") ], list.entries
  end

  test "ignores a malformed request" do
    list = Watchlist.new(nil)

    list.toggle("' OR 1=1", "")
    list.toggle("1", "bonus:1")
    list.toggle({ a: 1 }, nil)
    list.toggle([ "1" ], "")

    assert list.empty?
  end

  test "keeps the latest ones when full, and stays well under the size of a cookie" do
    list = Watchlist.new(nil)
    (1..Watchlist::LIMIT + 1).each { |id| list.toggle(200_000 + id, "pet:#{id}") }

    assert_equal Watchlist::LIMIT, list.size
    assert_not list.include?(200_001, "pet:1")
    assert list.include?(200_000 + Watchlist::LIMIT + 1, "pet:#{Watchlist::LIMIT + 1}")
    assert_operator list.to_cookie.bytesize, :<, 2_000
  end

  test "shows what is on sale on the markets it is given, and only that" do
    hyjal = create_market
    commodities = create_commodities
    other = create_market(connected_realm_id: 9, name: "Other")
    [ hyjal, commodities, other ].each { |market| create_snapshot(market, NOW) }
    create_item(1, name: "Linen Cloth")
    create_item(2, name: "Wool Cloth")
    create_item(3, name: "Silk Cloth")
    create_item(4, name: "Copper Ore")
    create_price(hyjal, 1, NOW)
    create_price(hyjal, 2, NOW)
    create_price(commodities, 4, NOW)
    create_price(other, 3, NOW)

    list = Watchlist.new(nil)
    list.toggle(1, "")
    list.toggle(3, "")
    list.toggle(4, "")

    products = list.products([ hyjal, commodities ])

    assert_equal [ [ commodities.id, 4 ], [ hyjal.id, 1 ] ], products.map { |row| [ row.auction_house_id, row.item_id ] }
    assert_equal "Copper Ore", products.first.name
    assert_equal 1, list.not_on_sale([ hyjal, commodities ])
    assert_equal [ 3 ], list.products([ other ]).map(&:item_id)
  end

  test "an empty list, or no market, asks nothing of the database" do
    assert_empty Watchlist.new(nil).products([ AuctionHouse.new(id: 1) ])
    assert_equal 0, Watchlist.new(nil).not_on_sale([])
    assert_empty Watchlist.new("1").products([])
  end
end
