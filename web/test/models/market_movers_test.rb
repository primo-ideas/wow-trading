require "test_helper"

class MarketMoversTest < ActiveSupport::TestCase
  ENOUGH = MarketMovers::MIN_AUCTIONS

  setup do
    @market = create_market
    create_snapshot(@market, NOW)
    create_snapshot(@market, NOW - 1.day)
  end

  def movers = MarketMovers.new(@market)

  def price_move(item_id, before, now, auctions: ENOUGH)
    create_item(item_id, name: "Objet nommé #{item_id}")
    create_unnamed_move(item_id, before, now, auctions: auctions)
  end

  def create_unnamed_move(item_id, before, now, auctions: ENOUGH)
    create_price(@market, item_id, NOW - 1.day, median: before, auctions: auctions)
    create_price(@market, item_id, NOW, median: now, auctions: auctions)
  end

  test "ranks the biggest rises and falls" do
    price_move(1, 100, 110)
    price_move(2, 100, 200)
    price_move(3, 100, 90)
    price_move(4, 100, 10)

    assert_equal [ 2, 1 ], movers.risers.map(&:item_id)
    assert_equal [ 4, 3 ], movers.fallers.map(&:item_id)
  end

  test "ignores what has too few listings to mean anything" do
    price_move(1, 100, 900, auctions: ENOUGH - 1)
    price_move(2, 100, 110)

    assert_equal [ 2 ], movers.risers.map(&:item_id)
  end

  test "an unchanged price is neither a rise nor a fall" do
    price_move(1, 100, 100)

    assert_empty movers.risers
    assert_empty movers.fallers
  end

  test "keeps to a few of each" do
    (1..MarketMovers::LIMIT + 2).each { |id| price_move(id, 100, 100 + id) }

    assert_equal MarketMovers::LIMIT, movers.risers.size
  end

  test "ranks what traded most by value" do
    price_move(1, 100, 100)
    price_move(2, 100, 100)
    price_move(3, 100, 100)
    create_sale(@market, 1, NOW, value: 500)
    create_sale(@market, 2, NOW, value: 900)

    assert_equal [ 2, 1 ], movers.most_traded.map(&:item_id)
  end

  test "leaves out what has no name yet, as it would tell a reader nothing" do
    price_move(1, 100, 110)
    create_unnamed_move(2, 100, 900)
    create_unnamed_move(3, 100, 10)
    create_sale(@market, 1, NOW, value: 100)
    create_sale(@market, 2, NOW, value: 900)

    assert_equal [ 1 ], movers.risers.map(&:item_id)
    assert_empty movers.fallers
    assert_equal [ 1 ], movers.most_traded.map(&:item_id)
  end

  test "a caged pet counts as named by its species" do
    create_pet(39, name: "Ecureuil mécanique")
    create_price(@market, 82800, NOW - 1.day, median: 100, auctions: ENOUGH, variant: "pet:39")
    create_price(@market, 82800, NOW, median: 200, auctions: ENOUGH, variant: "pet:39")

    assert_equal [ "Ecureuil mécanique" ], movers.risers.map(&:name)
  end

  test "without a day of history there is nothing to compare, but sales still show" do
    market = create_market(connected_realm_id: 9, name: "Récent")
    create_snapshot(market, NOW)
    create_item(1, name: "Objet nommé")
    create_price(market, 1, NOW)
    create_sale(market, 1, NOW)

    fresh = MarketMovers.new(market)

    assert_not fresh.compared?
    assert_empty fresh.risers
    assert_equal [ 1 ], fresh.most_traded.map(&:item_id)
  end
end
