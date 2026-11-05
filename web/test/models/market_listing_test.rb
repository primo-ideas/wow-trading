require "test_helper"

class MarketListingTest < ActiveSupport::TestCase
  setup do
    @market = create_market
    create_snapshot(@market, NOW)
    create_snapshot(@market, NOW - 1.day)
    create_item(2589, name: "Étoffe de lin")
    create_item(200000, name: "Épée de test")
  end

  test "lists the latest snapshot, not the older ones" do
    create_price(@market, 2589, NOW - 1.day, median: 900)
    create_price(@market, 2589, NOW, median: 1_000)
    create_price(@market, 200000, NOW - 1.day, median: 5_000)

    rows = MarketListing.new(@market).rows

    assert_equal [ 2589 ], rows.map(&:item_id)
    assert_equal 1_000, rows.first.median_price
  end

  test "compares to the snapshot from a day before" do
    create_price(@market, 2589, NOW - 1.day, median: 900)
    create_price(@market, 2589, NOW, median: 1_000)

    assert_equal 900, MarketListing.new(@market).rows.first.reference_median_price
  end

  test "has no comparison when no snapshot is close to a day old" do
    market = create_market(connected_realm_id: 1, name: "Récent")
    create_snapshot(market, NOW)
    create_snapshot(market, NOW - 3.days)
    create_price(market, 2589, NOW - 3.days, median: 900)
    create_price(market, 2589, NOW, median: 1_000)

    assert_nil MarketListing.new(market).rows.first.reference_median_price
  end

  test "sums the sales of the last day only" do
    create_price(@market, 2589, NOW)
    create_sale(@market, 2589, NOW, quantity: 3, value: 300)
    create_sale(@market, 2589, NOW - 23.hours, quantity: 4, value: 400)
    create_sale(@market, 2589, NOW - 2.days, quantity: 100, value: 10_000)

    row = MarketListing.new(@market).rows.first

    assert_equal 7, row.sold_quantity
    assert_equal 700, row.sold_value
  end

  test "keeps variants of an item apart" do
    create_price(@market, 82800, NOW, median: 100, variant: "pet:39")
    create_price(@market, 82800, NOW, median: 200, variant: "pet:40")
    create_sale(@market, 82800, NOW, quantity: 1, variant: "pet:39")

    rows = MarketListing.new(@market, sort: "price").rows

    assert_equal [ "pet:40", "pet:39" ], rows.map(&:variant)
    assert_nil rows.first.sold_quantity
    assert_equal 1, rows.last.sold_quantity
  end

  test "an item not looked up yet is still listed" do
    create_price(@market, 999999, NOW)

    row = MarketListing.new(@market).rows.first

    assert_equal 999999, row.item_id
    assert_nil row.name
  end

  test "searches names without regard for case or accents" do
    create_price(@market, 2589, NOW)
    create_price(@market, 200000, NOW)

    [ "etoffe", "ÉTOFFE", "toffe de", "Étoffe" ].each do |query|
      assert_equal [ 2589 ], MarketListing.new(@market, query: query).rows.map(&:item_id), query
    end
  end

  test "searches by item id" do
    create_price(@market, 2589, NOW)
    create_price(@market, 200000, NOW)

    assert_equal [ 200000 ], MarketListing.new(@market, query: "200000").rows.map(&:item_id)
  end

  test "search wildcards are taken literally" do
    create_price(@market, 2589, NOW)

    assert_empty MarketListing.new(@market, query: "%").rows
    assert_empty MarketListing.new(@market, query: "_toffe").rows
  end

  test "search text cannot change the query" do
    create_price(@market, 2589, NOW)

    assert_empty MarketListing.new(@market, query: "'; DROP TABLE items; --").rows
    assert Item.exists?(2589)
  end

  test "sorts names alphabetically, not in byte order" do
    create_item(3, name: "Zèbre")
    create_price(@market, 2589, NOW)
    create_price(@market, 3, NOW)

    assert_equal [ 2589, 3 ], MarketListing.new(@market, sort: "name").rows.map(&:item_id)
  end

  test "an unknown sort falls back to the default" do
    assert_equal MarketListing::DEFAULT_SORT, MarketListing.new(@market, sort: "1; DROP").sort
  end

  test "pages do not overlap" do
    stub_const(MarketListing, :PAGE_SIZE, 2) do
      [ 1, 2, 3 ].each { |id| create_price(@market, id, NOW) }

      first = MarketListing.new(@market, sort: "price")
      second = MarketListing.new(@market, sort: "price", page: "2")

      assert first.next_page?
      assert_not first.previous_page?
      assert_not second.next_page?
      assert second.previous_page?
      assert_equal [ 1, 2, 3 ], (first.rows + second.rows).map(&:item_id).sort
    end
  end

  test "a page that is not a number means the first" do
    assert_equal 1, MarketListing.new(@market, page: "abc").page
    assert_equal 1, MarketListing.new(@market, page: "-3").page
    assert_equal 1, MarketListing.new(@market, page: [ "2" ]).page
  end

  test "an absurd page is simply empty" do
    create_price(@market, 2589, NOW)

    assert_empty MarketListing.new(@market, page: "9" * 40).rows
  end

  test "a null byte in the search does not reach the database" do
    create_price(@market, 2589, NOW)

    assert_equal [ 2589 ], MarketListing.new(@market, query: "eto\0ffe").rows.map(&:item_id)
  end

  test "a market without a snapshot lists nothing" do
    market = create_market(connected_realm_id: 2, name: "Vide")

    assert_nil MarketListing.new(market).latest_taken_at
    assert_empty MarketListing.new(market).rows
  end

  private

  def stub_const(owner, name, value)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end
end
