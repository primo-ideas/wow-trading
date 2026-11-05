require "test_helper"

class MarketDealsTest < ActiveSupport::TestCase
  ENOUGH = ListedProduct::MIN_USUAL_POINTS
  GOLD = 10_000

  setup do
    @market = create_market
    create_snapshot(@market, NOW)
  end

  def deals(**options) = MarketDeals.new(@market, **options)

  def listed(item_id, min:, name: "Named #{item_id}", variant: "")
    create_item(item_id, name: name) unless Item.exists?(item_id)
    create_price(@market, item_id, NOW, min: min, median: min * 2, variant: variant)
  end

  # After every price, as each one makes the listing be worked out again.
  def usual(item_id, price, points: ENOUGH)
    ListedProduct.where(auction_house_id: @market.id, item_id: item_id)
      .update_all(usual_min_price: price, usual_min_points: points)
  end

  test "keeps what is well below its usual price, the biggest profit first" do
    listed(1, min: 10 * GOLD)
    listed(2, min: 100 * GOLD)
    listed(3, min: 100 * GOLD)
    usual(1, 20 * GOLD)
    usual(2, 200 * GOLD)
    usual(3, 110 * GOLD)

    assert_equal [ 2, 1 ], deals.rows.map(&:item_id)
    assert_equal 2, deals.total
  end

  test "counts the cut of the auction house" do
    listed(1, min: 10 * GOLD)
    usual(1, 20 * GOLD)
    row = deals.rows.first

    assert_equal 9 * GOLD, row.resale_profit
    assert_in_delta 0.5, row.discount
  end

  test "a margin that the cut eats is no deal" do
    listed(1, min: 100 * GOLD)
    usual(1, 125 * GOLD)

    assert_empty deals.rows
  end

  test "a good percentage of very little is no deal" do
    listed(1, min: 100)
    usual(1, 1_000)

    assert_empty deals.rows
  end

  test "a price with too little history is no deal" do
    listed(1, min: 10 * GOLD)
    usual(1, 20 * GOLD, points: ENOUGH - 1)

    assert_empty deals.rows
    assert_not deals.ready?
  end

  test "gear in several variants is no deal, as a low item level is not a bargain" do
    listed(1, min: 10 * GOLD, variant: "bonus:1")
    listed(1, min: 500 * GOLD, variant: "bonus:2")
    usual(1, 200 * GOLD)

    assert_empty deals.rows
    assert_nil ListedProduct.find_by(item_id: 1).usual_price
  end

  test "what has no name yet is left out, as it would tell a reader nothing" do
    create_price(@market, 1, NOW, min: 10 * GOLD)
    usual(1, 20 * GOLD)

    assert_empty deals.rows
  end

  test "a caged pet is a deal of its own, named after its species" do
    create_pet(39, name: "Mechanical Squirrel")
    create_price(@market, 82800, NOW, min: 10 * GOLD, variant: "pet:39")
    usual(82800, 20 * GOLD)

    assert_equal [ "Mechanical Squirrel" ], deals.rows.map(&:name)
  end

  test "can sort by discount or by sales, and falls back on profit" do
    listed(1, min: 10 * GOLD)
    listed(2, min: 100 * GOLD)
    create_sale(@market, 1, NOW, quantity: 9)
    usual(1, 100 * GOLD)
    usual(2, 200 * GOLD)

    assert_equal [ 2, 1 ], deals(sort: "profit").rows.map(&:item_id)
    assert_equal [ 1, 2 ], deals(sort: "discount").rows.map(&:item_id)
    assert_equal [ 1, 2 ], deals(sort: "sold").rows.map(&:item_id)
    assert_equal [ 2, 1 ], deals(sort: "1; DROP").rows.map(&:item_id)
  end

  test "says how far along a market is" do
    create_snapshot(@market, NOW - 1.hour)
    create_snapshot(@market, NOW - 4.days)

    assert_equal 2, deals.snapshots_so_far
  end

  test "the fetcher's function works out the usual cheapest price, without the latest" do
    [ [ NOW - 3.hours, 300 ], [ NOW - 2.hours, 100 ], [ NOW - 1.hour, 200 ] ].each do |taken_at, min|
      create_snapshot(@market, taken_at)
      create_price(@market, 1, taken_at, min: min)
    end
    create_price(@market, 1, NOW, min: 5)

    row = ListedProduct.find_by(auction_house_id: @market.id, item_id: 1)

    assert_equal 200, row.usual_min_price
    assert_equal 3, row.usual_min_points
    assert_equal 5, row.min_price
  end

  test "the usual price forgets what is more than three days old" do
    create_snapshot(@market, NOW - 4.days)
    create_price(@market, 1, NOW - 4.days, min: 900)
    create_price(@market, 1, NOW, min: 5)

    row = ListedProduct.find_by(auction_house_id: @market.id, item_id: 1)

    assert_nil row.usual_min_price
    assert_equal 0, row.usual_min_points
  end
end
