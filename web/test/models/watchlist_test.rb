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

    assert_equal [ Watchlist::Entry.new(2589, "", nil), Watchlist::Entry.new(82800, "pet:39", nil) ], list.entries
  end

  test "once written, its own cookie wins over the old one" do
    list = Watchlist.new("", legacy: "60.2589")

    assert list.empty?
  end

  test "ignores whatever a cookie holds that it did not write" do
    list = Watchlist.new("2589_abc_1.2.3_;DROP_.5_7.")

    assert_equal [ Watchlist::Entry.new(2589, "", nil) ], list.entries
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

  test "keeps a target price per product, through its cookie" do
    list = Watchlist.new(nil)
    list.set_target("2589", "", 125_000)
    list.set_target(82800, "pet:39", 7)

    restored = Watchlist.new(list.to_cookie)

    assert_equal "2589-125000_82800.39-7", list.to_cookie
    assert_equal 125_000, restored.target_for(2589, "")
    assert_equal 7, restored.target_for(82800, "pet:39")
    assert restored.targets?
  end

  test "setting a target follows the product, and taking it off keeps following it" do
    list = Watchlist.new(nil)

    list.set_target(2589, "", 100)
    assert list.include?(2589, "")

    list.set_target(2589, "", nil)
    assert list.include?(2589, "")
    assert_nil list.target_for(2589, "")
    assert_not list.targets?

    list.toggle(2589, "")
    assert list.empty?
  end

  test "ignores a target that makes no sense" do
    list = Watchlist.new("2589-0_2590-99999999999999_2591-abc_2592-50")

    assert_nil list.target_for(2589, "")
    assert_nil list.target_for(2590, "")
    assert_not list.include?(2591, "")
    assert_equal 50, list.target_for(2592, "")

    list.set_target(2589, "", -5)
    list.set_target(2589, "", "100")
    assert_nil list.target_for(2589, "")
  end

  test "flags what costs its target or less on the markets given" do
    market = create_market
    create_snapshot(market, NOW)
    create_item(1, name: "Linen Cloth")
    create_item(2, name: "Wool Cloth")
    create_item(3, name: "Silk Cloth")
    create_price(market, 1, NOW, min: 100)
    create_price(market, 2, NOW, min: 300)
    create_price(market, 3, NOW, min: 100)

    list = Watchlist.new(nil)
    list.set_target(1, "", 100)
    list.set_target(2, "", 200)
    list.toggle(3, "")

    assert_equal [ 1 ], list.at_target([ market ]).map(&:item_id)
    assert_empty Watchlist.new("3").at_target([ market ])
  end

  test "an empty list, or no market, asks nothing of the database" do
    assert_empty Watchlist.new(nil).products([ AuctionHouse.new(id: 1) ])
    assert_equal 0, Watchlist.new(nil).not_on_sale([])
    assert_empty Watchlist.new("1").products([])
  end
end
