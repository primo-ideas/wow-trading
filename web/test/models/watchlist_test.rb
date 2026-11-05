require "test_helper"

class WatchlistTest < ActiveSupport::TestCase
  test "adds a product, and removes it the second time" do
    list = Watchlist.new(nil)

    list.toggle("60", "2589", "")
    assert list.include?(60, 2589, "")

    list.toggle("60", "2589", "")
    assert_not list.include?(60, 2589, "")
    assert list.empty?
  end

  test "survives the trip through its cookie, with its pets" do
    list = Watchlist.new(nil)
    list.toggle(60, 2589, "")
    list.toggle(60, 82800, "pet:39")

    restored = Watchlist.new(list.to_cookie)

    assert restored.include?(60, 2589, "")
    assert restored.include?(60, 82800, "pet:39")
    assert_not restored.include?(60, 82800, "")
    assert_equal 2, restored.size
  end

  test "its cookie only holds characters that are not escaped" do
    list = Watchlist.new(nil)
    list.toggle(60, 2589, "")
    list.toggle(60, 82800, "pet:39")

    assert_equal list.to_cookie, CGI.escape(list.to_cookie)
  end

  test "ignores whatever a cookie holds that it did not write" do
    list = Watchlist.new("60.2589_abc_1.2.3.4_;DROP_.5_7.")

    assert_equal [ Watchlist::Entry.new(60, 2589, "") ], list.entries
  end

  test "ignores a malformed request" do
    list = Watchlist.new(nil)

    list.toggle("abc", "1", "")
    list.toggle("1", "' OR 1=1", "")
    list.toggle("1", "1", "bonus:1")
    list.toggle([ "1" ], { a: 1 }, nil)

    assert list.empty?
  end

  test "keeps the latest ones when full, and stays well under the size of a cookie" do
    list = Watchlist.new(nil)
    (1..Watchlist::LIMIT + 1).each { |id| list.toggle(999_999, 200_000 + id, "") }

    assert_equal Watchlist::LIMIT, list.size
    assert_not list.include?(999_999, 200_001, "")
    assert list.include?(999_999, 200_000 + Watchlist::LIMIT + 1, "")
    assert_operator list.to_cookie.bytesize, :<, 2_000
  end

  test "shows what is on sale on the markets it names, and only that" do
    hyjal = create_market
    other = create_market(connected_realm_id: 9, name: "Other")
    [ hyjal, other ].each { |market| create_snapshot(market, NOW) }
    create_item(1, name: "Linen Cloth")
    create_item(2, name: "Wool Cloth")
    create_item(3, name: "Silk Cloth")
    create_price(hyjal, 1, NOW)
    create_price(hyjal, 2, NOW)
    create_price(other, 1, NOW)

    list = Watchlist.new(nil)
    list.toggle(hyjal.id, 1, "")
    list.toggle(hyjal.id, 3, "")

    assert_equal [ [ hyjal.id, 1 ] ], list.products.map { |row| [ row.auction_house_id, row.item_id ] }
    assert_equal "Linen Cloth", list.products.first.name
    assert_equal 1, list.not_on_sale
  end

  test "an empty list asks nothing of the database" do
    assert_empty Watchlist.new(nil).products
    assert_equal 0, Watchlist.new(nil).not_on_sale
  end
end
