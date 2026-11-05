require "test_helper"

class MarketListingTest < ActiveSupport::TestCase
  setup do
    @market = create_market
    create_snapshot(@market, NOW)
    create_snapshot(@market, NOW - 1.day)
    create_item(2589, name: "Linen Cloth", item_class: "Tradeskill", quality: "COMMON")
    create_item(200000, name: "Test Sword", item_class: "Weapon", quality: "EPIC")
  end

  def listing(**options) = MarketListing.new(@market, **options)

  test "lists the latest snapshot, not the older ones" do
    create_price(@market, 2589, NOW - 1.day, median: 900)
    create_price(@market, 2589, NOW, median: 1_000)
    create_price(@market, 200000, NOW - 1.day, median: 5_000)

    rows = listing.rows

    assert_equal [ 2589 ], rows.map(&:item_id)
    assert_equal 1_000, rows.first.median_price
    assert_equal 1, listing.total
  end

  test "compares to the snapshot from a day before" do
    create_price(@market, 2589, NOW - 1.day, median: 800)
    create_price(@market, 2589, NOW, median: 1_000)

    row = listing.rows.first

    assert_equal 800, row.reference_median_price
    assert_in_delta 0.25, row.change
  end

  test "has no comparison when no snapshot is close to a day old" do
    market = create_market(connected_realm_id: 1, name: "Recent")
    create_snapshot(market, NOW)
    create_snapshot(market, NOW - 3.days)
    create_price(market, 2589, NOW - 3.days, median: 900)
    create_price(market, 2589, NOW, median: 1_000)

    row = MarketListing.new(market).rows.first

    assert_nil row.reference_median_price
    assert_nil row.change
    assert_not MarketListing.new(market).compared?
  end

  test "sums the sales of the last day only" do
    create_price(@market, 2589, NOW)
    create_sale(@market, 2589, NOW, quantity: 3, value: 300)
    create_sale(@market, 2589, NOW - 23.hours, quantity: 4, value: 400)
    create_sale(@market, 2589, NOW - 2.days, quantity: 100, value: 10_000)

    row = listing.rows.first

    assert_equal 7, row.sold_quantity
    assert_equal 700, row.sold_value
  end

  test "a piece of gear adds up into one product, whatever its bonus lists" do
    create_price(@market, 200000, NOW, median: 100, min: 90, quantity: 1, auctions: 1, variant: "bonus:1")
    create_price(@market, 200000, NOW, median: 400, min: 300, quantity: 3, auctions: 2, variant: "bonus:2")
    create_sale(@market, 200000, NOW, quantity: 1, value: 100, variant: "bonus:1")
    create_sale(@market, 200000, NOW, quantity: 2, value: 800, variant: "bonus:2")

    rows = listing.rows

    assert_equal 1, rows.size
    row = rows.first
    assert_equal "", row.series
    assert_nil row.variant_param
    assert row.several_variants?
    assert_equal 2, row.variant_count
    assert_equal 90, row.min_price
    assert_equal 325, row.median_price, "the median must be weighted by quantity"
    assert_equal 4, row.quantity
    assert_equal 3, row.auction_count
    assert_equal 3, row.sold_quantity
    assert_equal 900, row.sold_value
  end

  test "each caged pet stays its own product, named after its species" do
    create_item(82800, name: "Pet Cage", quality: "RARE")
    create_pet(39, name: "Mechanical Squirrel", icon_url: "https://render.example/39.jpg")
    create_pet(40, name: "Cat", icon_url: "https://render.example/40.jpg")
    create_price(@market, 82800, NOW, median: 100, variant: "pet:39")
    create_price(@market, 82800, NOW, median: 200, variant: "pet:40")
    create_sale(@market, 82800, NOW, quantity: 1, variant: "pet:39")

    rows = listing(sort: "price").rows

    assert_equal [ "pet:40", "pet:39" ], rows.map(&:series)
    assert_equal [ "Cat", "Mechanical Squirrel" ], rows.map(&:name)
    assert_equal [ "https://render.example/40.jpg", "https://render.example/39.jpg" ], rows.map(&:icon_url)
    assert_equal "pet:39", rows.last.variant_param
    assert_nil rows.first.sold_quantity
    assert_equal 1, rows.last.sold_quantity
  end

  test "a species the fetcher has not looked up yet still lists its cage" do
    create_item(82800, name: "Pet Cage")
    create_price(@market, 82800, NOW, variant: "pet:999")

    assert_equal "Pet Cage", listing.rows.first.name
  end

  test "an item not looked up yet is still listed" do
    create_price(@market, 999999, NOW)

    row = listing.rows.first

    assert_equal 999999, row.item_id
    assert_nil row.name
    assert_equal "Item #999999", row.display_name
  end

  test "searches names without regard for case or accents" do
    create_item(3, name: "Éclair")
    create_price(@market, 3, NOW)
    create_price(@market, 200000, NOW)

    [ "eclair", "ÉCLAIR", "clai", "Éclair" ].each do |query|
      assert_equal [ 3 ], listing(query: query).rows.map(&:item_id), query
    end
  end

  test "searches pets by the name of their species" do
    create_item(82800, name: "Pet Cage")
    create_pet(39, name: "Mechanical Squirrel")
    create_price(@market, 82800, NOW, variant: "pet:39")

    assert_equal [ "pet:39" ], listing(query: "squirrel").rows.map(&:series)
    assert_empty listing(query: "cage").rows
  end

  test "searches by item id" do
    create_price(@market, 2589, NOW)
    create_price(@market, 200000, NOW)

    assert_equal [ 200000 ], listing(query: "200000").rows.map(&:item_id)
  end

  test "search wildcards are taken literally" do
    create_price(@market, 2589, NOW)

    assert_empty listing(query: "%").rows
    assert_empty listing(query: "_inen").rows
  end

  test "search text cannot change the query" do
    create_price(@market, 2589, NOW)

    assert_empty listing(query: "'; DROP TABLE items; --").rows
    assert Item.exists?(2589)
  end

  test "filters on category and quality, and counts what remains" do
    create_price(@market, 2589, NOW)
    create_price(@market, 200000, NOW)

    assert_equal [ 200000 ], listing(item_class: "Weapon").rows.map(&:item_id)
    assert_equal [ 2589 ], listing(quality: "COMMON").rows.map(&:item_id)
    assert_empty listing(item_class: "Weapon", quality: "COMMON").rows
    assert_equal 1, listing(item_class: "Weapon").total
    assert listing(item_class: "Weapon").filtered?
    assert_not listing.filtered?
  end

  test "sorts names alphabetically, not in byte order" do
    create_item(3, name: "Zebra")
    create_item(4, name: "Éclair")
    create_price(@market, 3, NOW)
    create_price(@market, 4, NOW)

    assert_equal [ 4, 3 ], listing(sort: "name").rows.map(&:item_id)
  end

  test "each column has its natural direction, and can be reversed" do
    create_price(@market, 2589, NOW, median: 100, min: 50)
    create_price(@market, 200000, NOW, median: 900, min: 800)

    assert_equal "desc", listing(sort: "price").dir
    assert_equal [ 200000, 2589 ], listing(sort: "price").rows.map(&:item_id)
    assert_equal [ 2589, 200000 ], listing(sort: "price", dir: "asc").rows.map(&:item_id)
    assert_equal "asc", listing(sort: "min").dir
    assert_equal [ 2589, 200000 ], listing(sort: "min").rows.map(&:item_id)
  end

  test "sorting by change leaves products without one at the end, in both directions" do
    create_item(5, name: "New")
    create_price(@market, 2589, NOW - 1.day, median: 100)
    create_price(@market, 2589, NOW, median: 200)
    create_price(@market, 200000, NOW - 1.day, median: 100)
    create_price(@market, 200000, NOW, median: 50)
    create_price(@market, 5, NOW, median: 50)

    assert_equal [ 2589, 200000, 5 ], listing(sort: "change").rows.map(&:item_id)
    assert_equal [ 200000, 2589, 5 ], listing(sort: "change", dir: "asc").rows.map(&:item_id)
  end

  test "an unknown sort or direction falls back to the default" do
    assert_equal MarketListing::DEFAULT_SORT, listing(sort: "1; DROP").sort
    assert_equal "desc", listing(sort: "value", dir: "sideways").dir
  end

  test "pages do not overlap" do
    stub_const(MarketListing, :PAGE_SIZE, 2) do
      [ 1, 2, 3 ].each { |id| create_price(@market, id, NOW) }

      first = listing(sort: "price")
      second = listing(sort: "price", page: "2")

      assert first.next_page?
      assert_not first.previous_page?
      assert_not second.next_page?
      assert second.previous_page?
      assert_equal 2, first.page_count
      assert_equal [ 1, 2, 3 ], (first.rows + second.rows).map(&:item_id).sort
    end
  end

  test "a page that is not a number means the first" do
    assert_equal 1, listing(page: "abc").page
    assert_equal 1, listing(page: "-3").page
    assert_equal 1, listing(page: [ "2" ]).page
  end

  test "an absurd page is simply empty" do
    create_price(@market, 2589, NOW)

    assert_empty listing(page: "9" * 40).rows
  end

  test "a null byte in the search does not reach the database" do
    create_price(@market, 2589, NOW)

    assert_equal [ 2589 ], listing(query: "lin\0en").rows.map(&:item_id)
  end

  test "a market without a snapshot lists nothing" do
    market = create_market(connected_realm_id: 2, name: "Empty")

    assert_nil MarketListing.new(market).latest_taken_at
    assert_empty MarketListing.new(market).rows
    assert_equal 0, MarketListing.new(market).total
  end

  test "gives a page of products their recent curve" do
    create_price(@market, 2589, NOW)
    create_price(@market, 2589, NOW - 2.days, median: 800)
    create_price(@market, 2589, NOW - 3.days, median: 700)
    create_price(@market, 2589, NOW - 10.days, median: 1)

    page = listing

    assert_equal [ 700.0, 800.0, 1_000.0 ], page.sparkline(page.rows.first)
  end

  test "the curve of a piece of gear is weighted, and a pet's is its own" do
    create_item(82800, name: "Cage")
    create_pet(39)
    create_price(@market, 200000, NOW, median: 100, quantity: 1, variant: "bonus:1")
    create_price(@market, 200000, NOW, median: 400, quantity: 3, variant: "bonus:2")
    create_price(@market, 82800, NOW, median: 50, variant: "pet:39")
    create_price(@market, 82800, NOW, median: 70, variant: "pet:40")

    page = listing
    gear = page.rows.find { |row| row.item_id == 200000 }
    pet = page.rows.find { |row| row.series == "pet:39" }

    assert_equal [ 325.0 ], page.sparkline(gear)
    assert_equal [ 50.0 ], page.sparkline(pet)
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
